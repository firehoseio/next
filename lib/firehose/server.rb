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
                  :reconnect_max_delay, :database_url, :cleanup_threshold,
                  :watchdog_enabled, :watchdog_deadline, :watchdog_interval,
                  :tcp_keepalives_idle, :tcp_keepalives_interval, :tcp_keepalives_count,
                  :replay_on_reconnect

    def initialize
      @notify_max_bytes = NOTIFY_MAX_BYTES
      @reconnect_attempts = nil  # nil = unlimited
      @reconnect_delay = 1
      @reconnect_max_delay = 30
      @database_url = nil
      @cleanup_threshold = 100
      @watchdog_enabled = true
      @watchdog_deadline = 60        # seconds without heartbeat before force-reconnect
      @watchdog_interval = 10        # seconds between watchdog checks
      @tcp_keepalives_idle = 30
      @tcp_keepalives_interval = 10
      @tcp_keepalives_count = 3
      @replay_on_reconnect = true
      @registry = Registry.new
      @commands = ::Queue.new
      @wakeup_read, @wakeup_write = IO.pipe
      @running = false
      @started = false
      @start_mutex = Mutex.new
      @reconnects = 0
      @heartbeat_at = monotonic_now
      @outage_reported = false
      @cursors = {}
      @cursors_mutex = Mutex.new
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
        watchdog_alive: @watchdog&.alive?,
        seconds_since_heartbeat: (monotonic_now - @heartbeat_at).round(3),
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
      @watchdog&.stop
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
      if @registry.add(pg_id, callback, channel_name: channel)
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

    # Called by the watchdog (from another thread) to break a wedged
    # consumer out of IO.select / a hung PG call. Idempotent and safe
    # to invoke concurrently with the consumer thread: closing the
    # socket makes any in-flight PG op raise, and the wakeup_write
    # forces IO.select to return. The supervisor catches the error
    # and connect_with_retry reopens the connection.
    def force_reconnect!
      conn = @conn
      begin
        conn&.close
      rescue
        # Already closed, in a bad state, etc. — fine.
      end
      begin
        @wakeup_write.write_nonblock("x")
      rescue IO::WaitWritable, IOError
        # Pipe full or closed — we did what we could.
      end
    end

    # Recorded by the consumer thread on each loop iteration and read
    # by the watchdog. Plain instance-variable read/write on Ruby
    # references is atomic; no mutex needed.
    def heartbeat!
      @heartbeat_at = monotonic_now
    end

    def seconds_since_heartbeat
      monotonic_now - @heartbeat_at
    end

    # Watchdog liveness probe. Non-blocking; consumer updates its
    # heartbeat when processing the :ping. Safe to call from any thread.
    def enqueue_ping
      enqueue([:ping])
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

        if @watchdog_enabled && !@watchdog&.alive?
          @watchdog = Watchdog.new(self).tap(&:start)
        end

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

      replay_missed_messages if @replay_on_reconnect && @reconnects > 0
    end

    # After a reconnect, fan out any messages from the DB that postdate the
    # last id seen on each subscribed channel. Callbacks must be idempotent —
    # they may see messages already delivered if the NOTIFY landed before the
    # connection dropped. Client-side handlers typically dedupe via event id.
    def replay_missed_messages
      cursors = @cursors_mutex.synchronize { @cursors.dup }
      return if cursors.empty?

      cursors.each do |pg_id, last_id|
        channel_name = @registry.channel_name(pg_id)
        next unless channel_name
        stream = channel_name.delete_prefix(channel_prefix)

        messages = Models::Message.joins(:channel)
          .where(firehose_channels: { name: stream })
          .where("firehose_messages.id > ?", last_id)
          .order(:id)
          .limit(1000)

        count = 0
        messages.find_each do |msg|
          event = { id: msg.id, channel_id: msg.channel_id, sequence: msg.sequence, stream: stream, data: msg.data }
          @registry.notify(pg_id, event.to_json)
          count += 1
        end

        if count > 0
          Firehose.logger.info { "[Firehose] Replayed #{count} missed message(s) on #{stream}" }
        end
      end
    rescue => e
      # Don't let replay failures crash the supervisor — log and move on.
      Firehose.logger.error { "[Firehose] Replay failed: #{e.class}: #{e.message}" }
      report_error(e, stage: :replay)
    end

    def channel_prefix = "firehose:"

    # Force OS-level TCP keepalives so a dead network peer surfaces as a
    # socket error within ~60 seconds instead of blocking IO.select
    # indefinitely waiting for traffic on a half-open connection.
    def open_connection
      if @database_url
        PG.connect(append_keepalives_to_url(@database_url))
      else
        config = ActiveRecord::Base.connection_db_config.configuration_hash
        PG.connect(**keepalive_options, **{
          host: config[:host],
          port: config[:port],
          dbname: config[:database],
          user: config[:username],
          password: config[:password]
        }.compact)
      end
    end

    def keepalive_options
      {
        keepalives: 1,
        keepalives_idle: @tcp_keepalives_idle,
        keepalives_interval: @tcp_keepalives_interval,
        keepalives_count: @tcp_keepalives_count
      }
    end

    def append_keepalives_to_url(url)
      require "uri"
      uri = URI.parse(url)
      params = URI.decode_www_form(uri.query || "")
      keepalive_options.each { |k, v| params << [k.to_s, v.to_s] }
      uri.query = URI.encode_www_form(params)
      uri.to_s
    rescue URI::InvalidURIError
      url  # malformed URL — skip keepalives rather than refuse to connect
    end

    # Supervised main loop. Any exception restarts the loop with backoff
    # rather than killing the thread. The only clean exit is :shutdown.
    def run
      loop do
        begin
          connect_with_retry
          @outage_reported = false
          serve
          return  # clean shutdown
        rescue PG::Error, IOError => e
          Firehose.logger.warn { "[Firehose] Connection error: #{e.class}: #{e.message}. Reconnecting." }
          report_error(e, stage: :connection_lost) unless @outage_reported
          @outage_reported = true
          # drop through — connect_with_retry will back off
        rescue => e
          # A bug in processing — don't let it kill the thread. Log and retry.
          Firehose.logger.error {
            "[Firehose] Unexpected error: #{e.class}: #{e.message}\n" +
            (e.backtrace&.first(5)&.join("\n").to_s)
          }
          report_error(e, stage: :supervisor)
          sleep 1  # prevent hot loop on a persistent bug
        end
      end
    end

    def serve
      loop do
        heartbeat!
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
            report_error(e, stage: :reconnect_gave_up)
            raise
          end

          delay = [@reconnect_delay * (2 ** (@reconnects - 1)), @reconnect_max_delay].min
          Firehose.logger.warn {
            "[Firehose] Connect failed (attempt #{@reconnects}): #{e.message}. Retrying in #{delay}s."
          }
          heartbeat!  # so the watchdog doesn't hammer us during a long reconnect
          sleep delay
        end
      end
    end

    # Forward errors to Rails' error reporter (Sentry/Honeybadger/etc hook
    # into this), plus any user-supplied handler. Never raise from here.
    def report_error(error, stage:)
      if defined?(Rails) && Rails.respond_to?(:error) && Rails.error
        Rails.error.report(error, source: "firehose.server", context: {
          stage: stage,
          reconnects: @reconnects,
          subscribed_channels: @registry.size,
          command_queue_depth: @commands.size
        }, handled: true)
      end
    rescue => inner
      Firehose.logger.warn { "[Firehose] Error reporter failed: #{inner.class}: #{inner.message}" }
    end

    def drain_wakeup
      @wakeup_read.read_nonblock(1024)
    rescue IO::WaitReadable
      # Nothing to drain
    end

    def process_commands
      loop do
        cmd = @commands.pop(true)
        heartbeat!  # proves the thread is draining — watchdog relies on this

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
        in [:ping]
          # watchdog liveness probe — just touching the heartbeat above is enough.
          nil
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
        heartbeat!
        channel = notification[:relname]
        payload = notification[:extra]
        Firehose.logger.debug { "[Firehose] received #{channel}" }
        record_cursor(channel, payload)
        @registry.notify(channel, payload)
      end
    end

    # Track the newest message id seen per channel so that replay_missed_messages
    # knows where to resume after a reconnect. Parse defensively — user-facing
    # payloads are controlled by the broadcaster, but malformed JSON should not
    # crash the consumer.
    def record_cursor(pg_id, payload)
      id = JSON.parse(payload)["id"]
      return unless id.is_a?(Integer)
      @cursors_mutex.synchronize do
        current = @cursors[pg_id]
        @cursors[pg_id] = id if current.nil? || id > current
      end
    rescue JSON::ParserError
      # Non-JSON payload (e.g., from a non-firehose source on the same channel) — skip.
    end

    def monotonic_now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    # Thread-safe subscriber registry.
    # Tracks callbacks per channel and reports first-add / last-remove
    # so the server knows when to LISTEN / UNLISTEN. Also remembers the
    # original channel name (pre-hash) so replay can look up messages
    # in the DB after a reconnect.
    class Registry
      def initialize
        @channels = {}
        @names = {}
        @mutex = Mutex.new
      end

      def add(channel, callback, channel_name: nil)
        @mutex.synchronize do
          first = !@channels.key?(channel)
          (@channels[channel] ||= []) << callback
          @names[channel] ||= channel_name if channel_name
          first
        end
      end

      def remove(channel, callback)
        @mutex.synchronize do
          return false unless @channels[channel]&.delete(callback)

          if @channels[channel].empty?
            @channels.delete(channel)
            @names.delete(channel)
            true
          else
            false
          end
        end
      end

      def channel_name(pg_id)
        @mutex.synchronize { @names[pg_id] }
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

    # Watchdog thread — detects a wedged-but-alive consumer and forces
    # reconnection. Runs in its own thread with catch-all rescues so the
    # watchdog itself can never take the server down.
    #
    # Detection: consumer updates `heartbeat!` on every loop iteration
    # and on every command/notification processed. Watchdog checks the
    # heartbeat age on a fixed interval. If nothing has moved in
    # `watchdog_deadline` seconds AND there are commands backed up or
    # subscribers attached, it calls `server.force_reconnect!` — which
    # closes the PG socket and pokes the wakeup pipe. The supervisor
    # loop catches the resulting PG::Error and reconnects.
    #
    # The watchdog never calls `Thread#kill` or `Thread#raise` on the
    # consumer. Those primitives can corrupt shared state or leave the
    # Ruby VM in inconsistent states. Force-closing the socket is safe
    # and precisely targets what we need to recover from: a hung I/O
    # call. If the consumer legitimately isn't making progress for other
    # reasons, the reconnect is harmless — it re-issues LISTEN on all
    # subscribed channels.
    class Watchdog
      def initialize(server)
        @server = server
        @thread = nil
        @running = false
      end

      def start
        return if @thread&.alive?
        @running = true
        @thread = Thread.new { run }
        @thread.name = "firehose-watchdog"
        @thread.report_on_exception = false  # we log ourselves
      end

      def stop
        @running = false
        @thread&.join(2)
        @thread = nil
      end

      def alive?
        @thread&.alive? == true
      end

      private

      def run
        # Outer loop exists purely so a bug in the watchdog body can't
        # kill the watchdog itself. Every path back to this loop must
        # have slept to avoid burning CPU.
        loop do
          break unless @running
          begin
            tick
          rescue => e
            begin
              Firehose.logger.error { "[Firehose] Watchdog error: #{e.class}: #{e.message}" }
            rescue
              # Even logging can fail (e.g., closed IO during shutdown). Swallow.
            end
            sleep 1
          end
        end
      end

      def tick
        sleep @server.watchdog_interval
        return unless @running

        age = @server.seconds_since_heartbeat
        if age > @server.watchdog_deadline
          Firehose.logger.warn {
            "[Firehose] Watchdog: no consumer heartbeat in #{age.round(1)}s " \
            "(deadline #{@server.watchdog_deadline}s). Forcing reconnect."
          }
          @server.force_reconnect!
          # Reset our own expectations so we don't immediately re-trigger
          # while the supervisor is reconnecting.
          sleep @server.watchdog_deadline
        else
          # Probe liveness without doing anything PG-side. The consumer
          # will update the heartbeat when it processes this command.
          @server.enqueue_ping
        end
      end
    end
  end
end
