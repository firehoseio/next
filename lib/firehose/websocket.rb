require "async/websocket/adapters/rails"
require "async/queue"

module Firehose
  # WebSocket transport for Firehose.
  #
  # Usage:
  #   class CableController < ApplicationController
  #     include Firehose::WebSocket
  #
  #     before_action :authenticate_user!
  #
  #     def authorize_streams(streams)
  #       streams.select { |s| current_user.can_access?(s) }
  #     end
  #   end
  #
  # Route:
  #   match "cable", to: "cable#websocket", via: [:get, :connect]
  #
  # Protocol:
  #   Client sends:   { "command": "subscribe", "streams": ["a", "b"], "last_event_id": 123 }
  #   Client sends:   { "command": "unsubscribe", "streams": ["a"] }
  #   Server sends:   { "id": 456, "stream": "a", "data": "refresh" }
  #
  module WebSocket
    extend ActiveSupport::Concern
    include Streamable

    # Seconds between server-initiated WS ping frames when the stream is
    # idle. Browsers auto-respond with pong frames at the protocol level
    # (RFC 6455), so no client code is needed.
    PING_INTERVAL = 30

    # Deadline after which a lack of pong is treated as a dead client.
    # Two missed pings — generous enough to tolerate jittery networks,
    # tight enough to reclaim leaked half-open connections promptly.
    PONG_TIMEOUT = 90

    # Upper bound on per-connection outgoing queue depth. A healthy client
    # drains events as fast as the server produces them; if the queue
    # fills, the client is too slow (bad network, backgrounded tab that
    # stopped reading). We disconnect rather than buffering without bound.
    # Clients reconnect and receive replay_gap if their cursor is stale.
    QUEUE_LIMIT = 1000

    def websocket
      self.response = Async::WebSocket::Adapters::Rails.open(request) do |connection|
        handler = WebSocketHandler.new(connection, controller: self)
        handler.run
      end
    end

    class WebSocketHandler
      def initialize(connection, controller:)
        @connection = connection
        @controller = controller
        @streams = Set.new
        @subscriptions = Firehose.server.subscriptions
        @queue = Async::Queue.new
        @queue_limit = QUEUE_LIMIT
        @overflow = false
        @last_pong_at = monotonic_now
        install_pong_tracker
      end

      def run
        task = Async::Task.current

        writer_task = task.async do
          write_messages
        end

        read_messages
        writer_task.stop
      rescue Protocol::WebSocket::ClosedError, EOFError, Async::Stop
        # Client disconnected
      ensure
        @subscriptions.close
        @streams.clear
        @queue.close
      end

      private

      # Override the connection's pong handler so we can track liveness.
      # Pings are sent from write_messages below; pongs arrive via the
      # read fiber, which calls into the connection's receive_pong.
      def install_pong_tracker
        tracker = self
        @connection.define_singleton_method(:receive_pong) do |_frame|
          tracker.send(:record_pong)
        end
      end

      def record_pong
        @last_pong_at = monotonic_now
      end

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def read_messages
        while (message = @connection.read)
          handle_message(JSON.parse(message.to_str))
        end
      rescue JSON::ParserError
        # Ignore malformed messages
      end

      # Owns the only write path to the connection: event frames AND
      # heartbeat pings. Piggybacking pings here avoids concurrent-write
      # races with a separate heartbeat fiber.
      #
      # When idle (dequeue times out), send a ping if we're overdue.
      # If no pong has been seen within PONG_TIMEOUT, close the connection
      # — read_messages will exit cleanly via ClosedError.
      def write_messages
        loop do
          payload = @queue.dequeue(timeout: PING_INTERVAL)

          if payload.nil?
            if monotonic_now - @last_pong_at > PONG_TIMEOUT
              Firehose.logger.warn {
                "[Firehose] WebSocket pong timeout (> #{PONG_TIMEOUT}s), closing connection"
              }
              @connection.close
              return
            end
            @connection.send_ping
            next
          end

          event = JSON.parse(payload, symbolize_names: true)
          event = resolve_event(event) unless event.key?(:data)
          send_event(event) if event
        end
      rescue Async::Stop
        # Task stopped
      end

      def resolve_event(event)
        msg = Models::Message.includes(:channel).find_by(id: event[:id])
        return unless msg
        { id: msg.id, channel_id: msg.channel_id, sequence: msg.sequence, stream: msg.channel.name, data: msg.data }
      end

      def handle_message(msg)
        case msg["command"]
        when "subscribe"
          subscribe(msg["streams"] || [], msg["last_event_id"].to_i)
        when "unsubscribe"
          unsubscribe(msg["streams"] || [])
        end
      end

      def subscribe(streams, last_event_id)
        streams = Array(streams).map(&:to_s)
        streams = @controller.authorize_streams(streams)

        new_streams = streams - @streams.to_a
        @streams.merge(new_streams)

        replay_events(new_streams, last_event_id) if new_streams.any? && last_event_id > 0

        new_streams.each do |stream|
          @subscriptions.add(stream) { |payload| enqueue_or_disconnect(payload) }
        end
      end

      # Called from the Firehose consumer thread — must return quickly so
      # we don't block other subscribers. If our queue is full, the client
      # is draining too slowly: close the connection (cleanup runs via the
      # rescue in #run) and stop accepting more events. The client will
      # reconnect and hit replay_gap if its cursor has aged past retention.
      def enqueue_or_disconnect(payload)
        if @queue.size >= @queue_limit
          return if @overflow
          @overflow = true
          Firehose.logger.warn {
            "[Firehose] WS queue depth #{@queue.size} >= #{@queue_limit}; disconnecting slow client"
          }
          begin
            @connection.close
          rescue => e
            Firehose.logger.debug { "[Firehose] Error closing overflow client: #{e.message}" }
          end
        else
          @queue.enqueue(payload)
        end
      end

      def unsubscribe(streams)
        Array(streams).map(&:to_s).each do |stream|
          @streams.delete(stream)
          @subscriptions.remove(stream)
        end
      end

      # Replay messages the client missed, per stream. If a stream's
      # oldest retained message is newer than last_event_id, the gap
      # exceeds our retention window — emit a replay_gap error for that
      # stream so the client can decide how to recover (reload, API
      # refetch, surface to user). Streams with an intact window get
      # normal replay.
      def replay_events(streams, since_id)
        channels = Models::Channel.where(name: streams).to_a
        channels.each do |ch|
          oldest = ch.messages.minimum(:id)
          next unless oldest  # no messages at all — nothing to replay

          if oldest > since_id
            current = ch.messages.maximum(:id)
            send_event(
              error: "replay_gap",
              stream: ch.name,
              last_event_id: since_id,
              oldest_retained_id: oldest,
              current_id: current
            )
            next
          end

          ch.messages
            .where("id > ?", since_id)
            .order(:id)
            .find_each { |msg| send_event(id: msg.id, channel_id: msg.channel_id, sequence: msg.sequence, stream: ch.name, data: msg.data) }
        end
      end

      def send_event(event)
        event = @controller.build_event(event.transform_keys(&:to_sym))
        return unless event

        message = Protocol::WebSocket::TextMessage.generate(event)
        @connection.write(message)
        @connection.flush
      end
    end
  end
end
