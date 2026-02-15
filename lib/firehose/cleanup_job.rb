module Firehose
  class CleanupJob < ActiveJob::Base
    # Keeps the last N events per stream (configurable via Firehose.cleanup_threshold)
    def perform(stream)
      cutoff_id = Event
        .where(stream:)
        .order(id: :desc)
        .offset(Firehose.cleanup_threshold)
        .limit(1)
        .pick(:id)

      return unless cutoff_id

      Event.where(stream:).where("id <= ?", cutoff_id).delete_all
    end
  end
end
