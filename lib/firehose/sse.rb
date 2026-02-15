require "async/queue"

module Firehose
  # SSE (Server-Sent Events) transport for Firehose.
  #
  # Usage:
  #   class CableController < ApplicationController
  #     include Firehose::SSE
  #
  #     before_action :authenticate_user!
  #
  #     def authorize_streams(streams)
  #       streams.select { |s| current_user.can_access?(s) }
  #     end
  #   end
  #
  # Route:
  #   get "cable/sse", to: "cable#sse"
  #
  # Client:
  #   const source = new EventSource("/cable/sse?streams=foo,bar")
  #   source.addEventListener("foo", (e) => console.log(e.data))
  #
  # Replay:
  #   Browser automatically sends Last-Event-ID header on reconnect.
  #
  module SSE
    extend ActiveSupport::Concern
    include Streamable

    def sse
      streams = parse_sse_streams
      streams = authorize_streams(streams)

      if streams.empty?
        head :forbidden
        return
      end

      response.headers["Content-Type"] = "text/event-stream"
      response.headers["Cache-Control"] = "no-cache, no-store"
      response.headers["X-Accel-Buffering"] = "no"
      response.headers["Connection"] = "keep-alive"

      handler = SSEHandler.new(request, response, streams:, controller: self)
      handler.run
    end

    private

    def parse_sse_streams
      streams_param = params[:streams]
      return [] unless streams_param

      streams_param.split(",").map(&:strip).reject(&:empty?)
    end

    class SSEHandler
      def initialize(request, response, streams:, controller:)
        @request = request
        @response = response
        @streams = streams
        @controller = controller
        @subscriptions = Firehose.server.subscriptions
        @queue = Async::Queue.new
      end

      def run
        task = Async::Task.current

        writer_task = task.async do
          write_messages
        end

        replay_events
        subscribe_to_streams
        writer_task.wait
      rescue Protocol::HTTP::Error, EOFError, Async::Stop, IOError, Errno::EPIPE
        # Client disconnected
      ensure
        writer_task&.stop
        @subscriptions.close
        @queue.close
      end

      private

      def last_event_id
        @request.headers["Last-Event-ID"].to_i
      end

      def replay_events
        return unless last_event_id > 0

        channels = Models::Channel.where(name: @streams)
        Models::Message
          .where(channel_id: channels.select(:id))
          .where("id > ?", last_event_id)
          .includes(:channel)
          .order(:id)
          .find_each { |msg| write_event(id: msg.id, channel_id: msg.channel_id, sequence: msg.sequence, stream: msg.channel.name, data: msg.data) }
      end

      def subscribe_to_streams
        @streams.each do |stream|
          @subscriptions.add(stream) { |payload| @queue.enqueue(payload) }
        end

        # Keep connection open waiting for events
        sleep
      rescue Async::Stop
        # Task stopped
      end

      def write_messages
        while (payload = @queue.dequeue)
          event = JSON.parse(payload, symbolize_names: true)
          event = resolve_event(event) unless event.key?(:data)
          write_event(event) if event
        end
      rescue Async::Stop
        # Task stopped
      end

      def resolve_event(event)
        msg = Models::Message.includes(:channel).find_by(id: event[:id])
        return unless msg
        { id: msg.id, channel_id: msg.channel_id, sequence: msg.sequence, stream: msg.channel.name, data: msg.data }
      end

      def write_event(event)
        event = event.transform_keys(&:to_sym)
        event = @controller.build_event(event)
        return unless event

        body = @response.body
        body.write("id: #{event[:id]}\n")
        body.write("event: #{event[:stream]}\n")
        data = { data: event[:data], channel_id: event[:channel_id], sequence: event[:sequence] }.to_json
        body.write("data: #{data}\n\n")
      end
    end
  end
end
