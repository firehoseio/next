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
        @subscriptions = Firehose.server.subscriptions
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
        @subscriptions.close
        @streams.clear
        @queue.close
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
        while (payload = @queue.dequeue)
          event = JSON.parse(payload, symbolize_names: true)
          event = resolve_event(event) unless event.key?(:data)
          send_event(event) if event
        end
      rescue Async::Stop
        # Task stopped
      end

      def resolve_event(event)
        msg = Message.includes(:channel).find_by(id: event[:id])
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
          @subscriptions.add(stream) { |payload| @queue.enqueue(payload) }
        end
      end

      def unsubscribe(streams)
        Array(streams).map(&:to_s).each do |stream|
          @streams.delete(stream)
          @subscriptions.remove(stream)
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
    end
  end
end
