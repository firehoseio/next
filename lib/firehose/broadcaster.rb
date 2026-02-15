module Firehose
  module Broadcaster
    class << self
      def broadcast(stream, data)
        stream = stream.to_s
        data = data.to_s

        channel = Channel.find_or_create_by!(name: stream)

        message = channel.with_lock do
          channel.increment!(:sequence)
          channel.messages.create!(sequence: channel.sequence, data:)
        end

        ActionCable.server.pubsub.broadcast(
          channel_name(stream),
          { id: message.id, channel_id: channel.id, sequence: message.sequence, stream:, data: }.to_json
        )

        if channel.messages.count > Firehose.cleanup_threshold
          CleanupJob.perform_later(stream)
        end

        message
      end

      def channel_name(stream)
        "firehose:#{stream}"
      end
    end
  end
end
