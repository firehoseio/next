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
        @subscriptions = {}
        @queue = Async::Queue.new
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
        cleanup
      end

      private

      def read_messages
        while (message = @connection.read)
          handle_message(JSON.parse(message.to_str))
        end
      rescue JSON::ParserError
        # Ignore malformed messages
      end

      def write_messages
        while (event = @queue.dequeue)
          send_event(event)
        end
      rescue Async::Stop
        # Task stopped
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
          channel = Broadcaster.channel_name(stream)
          callback = ->(message) {
            data = message.respond_to?(:data) ? message.data : message
            @queue.enqueue(JSON.parse(data))
          }
          ActionCable.server.pubsub.subscribe(channel, callback)
          @subscriptions[stream] = callback
        end
      end

      def unsubscribe(streams)
        streams = Array(streams).map(&:to_s)

        streams.each do |stream|
          @streams.delete(stream)
          if @subscriptions[stream]
            ActionCable.server.pubsub.unsubscribe(
              Broadcaster.channel_name(stream),
              @subscriptions.delete(stream)
            )
          end
        end
      end

      def replay_events(streams, since_id)
        channels = Channel.where(name: streams)
        Message
          .where(channel_id: channels.select(:id))
          .where("id > ?", since_id)
          .includes(:channel)
          .order(:id)
          .find_each { |msg| send_event(id: msg.id, channel_id: msg.channel_id, sequence: msg.sequence, stream: msg.channel.name, data: msg.data) }
      end

      def send_event(event)
        event = @controller.build_event(event.transform_keys(&:to_sym))
        return unless event

        message = Protocol::WebSocket::TextMessage.generate(event)
        @connection.write(message)
        @connection.flush
      end

      def cleanup
        @subscriptions.each do |stream, callback|
          ActionCable.server.pubsub.unsubscribe(Broadcaster.channel_name(stream), callback)
        end
        @subscriptions.clear
        @streams.clear
        @queue.close
      end
    end
  end
end
