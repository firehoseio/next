module Firehose
  class CleanupJob < ActiveJob::Base
    def perform(stream)
      channel = Channel.find_by(name: stream)
      return unless channel

      cutoff_id = channel.messages
        .order(sequence: :desc)
        .offset(Firehose.server.cleanup_threshold)
        .limit(1)
        .pick(:id)

      return unless cutoff_id

      channel.messages.where("id <= ?", cutoff_id).delete_all
      channel.update_columns(messages_count: channel.messages.count)

      channel.destroy if channel.messages_count == 0
    end
  end
end
