# Shared base for WebSocket and SSE transports.
# Include this module to get the callback interface without a transport.
#
# Callbacks (override in controller):
#   authorize_streams(streams) - Filter which streams user can subscribe to
#   build_event(event)         - Transform event hash before sending, or nil to skip
#
module Firehose
  module Streamable
    extend ActiveSupport::Concern

    # Override to authorize stream access.
    # Return only the streams the user is allowed to subscribe to.
    def authorize_streams(streams)
      streams
    end

    # Override to transform events before sending.
    # Return nil to skip sending the event.
    # Event is a hash: { id:, stream:, data: }
    def build_event(event)
      event
    end

    private

    def firehose_replay_events(streams, since_id)
      Event
        .where(stream: streams)
        .where("id > ?", since_id)
        .order(:id)
    end

    def firehose_subscribe(streams, queue)
      subscriptions = {}

      streams.each do |stream|
        channel = Broadcaster.channel_name(stream)
        callback = ->(message) {
          data = message.respond_to?(:data) ? message.data : message
          queue << JSON.parse(data)
        }
        ActionCable.server.pubsub.subscribe(channel, callback)
        subscriptions[stream] = callback
      end

      subscriptions
    end

    def firehose_unsubscribe(subscriptions)
      subscriptions.each do |stream, callback|
        ActionCable.server.pubsub.unsubscribe(Broadcaster.channel_name(stream), callback)
      end
    end
  end
end
