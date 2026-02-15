module Firehose
  module Broadcaster
    class << self
      def broadcast(stream, data)
        stream = stream.to_s
        data = data.to_s

        # Persist for replay via Last-Event-ID
        event = Event.create!(stream:, data:)

        # Instant delivery via PostgreSQL LISTEN/NOTIFY
        ActionCable.server.pubsub.broadcast(
          channel_name(stream),
          { id: event.id, stream:, data: }.to_json
        )

        # Schedule cleanup if threshold exceeded
        if Event.where(stream:).count > Firehose.cleanup_threshold
          CleanupJob.perform_later(stream)
        end

        event
      end

      def channel_name(stream)
        "firehose:#{stream}"
      end
    end
  end
end
