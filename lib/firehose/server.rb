require "json"
require "digest"

module Firehose
  # Single-connection PG pubsub server. One per process.
  #
  # Handles LISTEN/NOTIFY over a dedicated PG connection outside the AR pool.
  # Producers enqueue commands (non-blocking), the background thread dispatches
  # them and fans out notifications to in-process subscribers.
  #
  # Scaling: this server uses a single PG connection for all operations.
  # LISTEN must stay on one connection (PG requirement), but NOTIFY could be
  # dispatched across a pool of connections for higher write throughput.
  # To implement: replace the single @conn with a pool in process_commands,
  # routing :notify commands to pool connections while keeping :listen/:unlisten
  # on the dedicated listener connection.
  class Server
    QUEUE_DEPTH_WARNING = 10_000

    # PG NOTIFY payload hard limit (7999 bytes + null terminator).
    # Not queryable at runtime — hardcoded in PG source as NOTIFY_PAYLOAD_MAX_LENGTH.
    NOTIFY_MAX_BYTES = 7999

    attr_accessor :notify_max_bytes, :reconnect_attempts, :reconnect_delay,
                  :reconnect_max_delay, :database_url, :cleanup_threshold

    def initialize
      @notify_max_bytes = NOTIFY_MAX_BYTES
      @reconnect_attempts = nil  # nil = unlimited
      @reconnect_delay = 1
      @reconnect_max_delay = 30
      @database_url = nil
      @cleanup_threshold = 100
      @registry = Registry.new
      @commands = ::Queue.new
      @wakeup_read, @wakeup_write = IO.pipe
      @running = false
      @started = false
      @start_mutex = Mutex.new
      @reconnects = 0
    end

    # Snapshot of runtime state. Safe to call from any thread — useful
    # from an admin endpoint or the firehose CLI to verify the consumer
    # thread is alive and draining.
    def diagnostics
      {
        pid: Process.pid,
        running: @running,
        started: @started,
        thread_alive: @thread&.alive?,
        thread_status: @thread&.status,
        command_queue_depth: @commands.size,
        reconnects: @reconnects,
        subscribed_channels: @registry.size
      }
    end

    def configure
      yield self
    end

    def configure_from_yaml(path)
      settings = YAML.safe_load_file(path, aliases: true).fetch(Rails.env, {})
      configure_from_hash(settings)
    end

    def configure_from_hash(hash)
      hash.each { |key, value| public_send(:"#{key}=", value) }
    end

    def start
      # Mark as ready but don't connect yet — connection is lazy.
      @running = true
      self
    end

    def shutdown
      return unless @running
      @running = false
      return unless @started
      Firehose.logger.info { "[Firehose] Server shutting down" }
      enqueue([:shutdown])
      @thread&.join(5)
      @conn&.close
      @wakeup_read&.close
      @wakeup_write&.close
    end

    def broadcast(stream, data)
      ensure_started!
      stream = stream.to_s
      data = data.to_s

      channel = Models::Channel.find_or_create_by!(name: stream)

      message = channel.with_lock do
        channel.increment!(:sequence)
        channel.messages.create!(sequence: channel.sequence, data:)
      end

      Firehose.logger.info { "[Firehose] broadcast stream=#{stream} sequence=#{message.sequence} id=#{message.id}" }

      event = { id: message.id, channel_id: message.channel_id, sequence: message.sequence, stream:, data: }
      payload = event.to_json
      payload = event.except(:data).to_json if payload.bytesize > @notify_max_bytes

      notify(channel_name(stream), payload)

      if channel.reload.messages_count > @cleanup_threshold
        CleanupJob.perform_later(stream)
      end

      message
    end

    class PayloadTooLarge < StandardError; end

    def notify(channel, payload)
      if payload.bytesize > @notify_max_bytes
        raise PayloadTooLarge, "Payload #{payload.bytesize}B exceeds PG NOTIFY limit of #{@notify_max_bytes}B on #{channel}"
      end
      pg_id = pg_identifier(channel)
      Firehose.logger.debug { "[Firehose] NOTIFY #{channel} [#{pg_id}] (#{payload.bytesize}B)" }
      enqueue([:notify, pg_id, payload])
    end

    def channel_name(stream)
      "firehose:#{stream}"
    end

    def subscribe(channel, callback)
      ensure_started!
      pg_id = pg_identifier(channel)
      if @registry.add(pg_id, callback)
        Firehose.logger.debug { "[Firehose] LISTEN #{channel} [#{pg_id}]" }
        enqueue([:listen, pg_id])
      end
    end

    def unsubscribe(channel, callback)
      pg_id = pg_identifier(channel)
      if @registry.remove(pg_id, callback)
        Firehose.logger.debug { "[Firehose] UNLISTEN #{channel} [#{pg_id}]" }
        enqueue([:unlisten, pg_id])
      end
    end

    def subscriptions
      Subscriptions.new(server: self)
    end

    def queue(channel)
      Queue.new(channel, server: self)
    end

    private

    PG_IDENTIFIER_MAX = 63

    # SHA256 hex digest of the channel name, used as the PG LISTEN/NOTIFY
    # identifier. PG silently truncates identifiers beyond 63 chars, which
    # would cause LISTEN and NOTIFY to target different channels. Hashing
    # guarantees a safe, fixed-length identifier for any input.
    def pg_identifier(channel)
      Digest::SHA256.hexdigest(channel).first(PG_IDENTIFIER_MAX)
    end

    def assert_pg_identifier!(identifier)
      raise ArgumentError, "PG channel identifier too long (#{identifier.length}/#{PG_IDENTIFIER_MAX}): #{identifier}" if identifier.length > PG_IDENTIFIER_MAX
    end

    def ensure_started!
      return if @started && @thread&.alive?

      @start_mutex.synchronize do
        return if @started && @thread&.alive?

        if @started
          Firehose.logger.warn { "[Firehose] Consumer thread died, respawning pid=#{Process.pid}" }
        end

        @thread = Thread.new { run }
        @thread.name = "firehose-server"
        @started = true
        Firehose.logger.info { "[Firehose] Server started pid=#{Process.pid}" }
      end
    end

    def enqueue(command)
      depth = @commands.size
      if depth > QUEUE_DEPTH_WARNING
        Firehose.logger.warn {
          "[Firehose] Command queue depth: #{depth}. " \
          "Single PG connection may be saturated. " \
          "See Server docs for connection pool guidance."
        }
      end

      @commands.push(command)
      @wakeup_write.write_nonblock("x")
    rescue IO::WaitWritable
      # Pipe buffer full — thread will drain it
    end

    def connect
      @conn&.close rescue nil
      @conn = open_connection
      @registry.each_channel { |ch| @conn.exec("LISTEN #{@conn.escape_identifier(ch)}") }
      Firehose.logger.debug { "[Firehose] Connected" }
    end

    def open_connection
      if @database_url
        PG.connect(@database_url)
      else
        config = ActiveRecord::Base.connection_db_config.configuration_hash
        PG.connect(
          host: config[:host],
          port: config[:port],
          dbname: config[:database],
          user: config[:username],
          password: config[:password]
        )
      end
    end

    # Supervised main loop. Any exception restarts the loop with backoff
    # rather than killing the thread. The only clean exit is :shutdown.
    def run
      loop do
        begin
          connect_with_retry
          serve
          return  # clean shutdown
        rescue PG::Error, IOError => e
          Firehose.logger.warn { "[Firehose] Connection error: #{e.class}: #{e.message}. Reconnecting." }
          # drop through — connect_with_retry will back off
        rescue => e
          # A bug in processing — don't let it kill the thread. Log and retry.
          Firehose.logger.error {
            "[Firehose] Unexpected error: #{e.class}: #{e.message}\n" +
            (e.backtrace&.first(5)&.join("\n").to_s)
          }
          sleep 1  # prevent hot loop on a persistent bug
        end
      end
    end

    def serve
      loop do
        IO.select([@conn.socket_io, @wakeup_read])
        drain_wakeup
        return unless process_commands
        receive_notifications
      end
    end

    # Connect to PG, retrying forever (or up to @reconnect_attempts) with
    # capped exponential backoff. Re-issues LISTEN for every registered channel.
    def connect_with_retry
      loop do
        begin
          connect
          @reconnects = 0
          return
        rescue PG::Error, IOError => e
          @reconnects += 1
          if @reconnect_attempts && @reconnects > @reconnect_attempts
            Firehose.logger.error {
              "[Firehose] Giving up after #{@reconnect_attempts} reconnect attempts: #{e.message}"
            }
            raise
          end

          delay = [@reconnect_delay * (2 ** (@reconnects - 1)), @reconnect_max_delay].min
          Firehose.logger.warn {
            "[Firehose] Connect failed (attempt #{@reconnects}): #{e.message}. Retrying in #{delay}s."
          }
          sleep delay
        end
      end
    end

    def drain_wakeup
      @wakeup_read.read_nonblock(1024)
    rescue IO::WaitReadable
      # Nothing to drain
    end

    def process_commands
      loop do
        cmd = @commands.pop(true)

        case cmd
        in [:listen, channel]
          assert_pg_identifier!(channel)
          @conn.exec("LISTEN #{@conn.escape_identifier(channel)}")
        in [:unlisten, channel]
          assert_pg_identifier!(channel)
          @conn.exec("UNLISTEN #{@conn.escape_identifier(channel)}")
        in [:notify, channel, payload]
          assert_pg_identifier!(channel)
          pg_notify(channel, payload)
        in [:shutdown]
          return false
        end
      end
    rescue ThreadError
      # Queue empty — done processing
      true
    end

    def pg_notify(channel, payload)
      @conn.exec_params("SELECT pg_notify($1, $2)", [channel, payload])
    end

    def receive_notifications
      @conn.consume_input
      while (notification = @conn.notifies)
        channel = notification[:relname]
        Firehose.logger.debug { "[Firehose] received #{channel}" }
        @registry.notify(channel, notification[:extra])
      end
    end

    # Thread-safe subscriber registry.
    # Tracks callbacks per channel and reports first-add / last-remove
    # so the server knows when to LISTEN / UNLISTEN.
    class Registry
      def initialize
        @channels = {}
        @mutex = Mutex.new
      end

      def add(channel, callback)
        @mutex.synchronize do
          first = !@channels.key?(channel)
          (@channels[channel] ||= []) << callback
          first
        end
      end

      def remove(channel, callback)
        @mutex.synchronize do
          return false unless @channels[channel]&.delete(callback)

          if @channels[channel].empty?
            @channels.delete(channel)
            true
          else
            false
          end
        end
      end

      def notify(channel, payload)
        callbacks = @mutex.synchronize { @channels[channel]&.dup }
        callbacks&.each do |cb|
          cb.call(payload)
        rescue => e
          Firehose.logger.error { "[Firehose] Callback error on #{channel}: #{e.message}" }
        end
      end

      def each_channel(&)
        channels = @mutex.synchronize { @channels.keys }
        channels.each(&)
      end

      def size
        @mutex.synchronize { @channels.size }
      end
    end

    # Manages a set of stream subscriptions with automatic cleanup.
    # Compose this instead of manually tracking subscription hashes.
    #
    # Notifications carry event JSON. When the data fits within PG's
    # 8KB NOTIFY limit, the full event is inline (no DB hit). For
    # oversized payloads, data is omitted and consumers fetch by ID.
    # Replay on reconnect always fetches from the database.
    class Subscriptions
      def initialize(server: Firehose.server)
        @server = server
        @subscriptions = {}
      end

      def add(stream, &on_notify)
        remove(stream) if @subscriptions.key?(stream)
        @server.subscribe(@server.channel_name(stream), on_notify)
        @subscriptions[stream] = on_notify
      end

      def remove(stream)
        return unless (callback = @subscriptions.delete(stream))
        @server.unsubscribe(@server.channel_name(stream), callback)
      end

      def close
        @subscriptions.keys.each { |stream| remove(stream) }
      end
    end
  end
end
