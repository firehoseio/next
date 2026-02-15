module Firehose
  class Message < ActiveRecord::Base
    self.table_name = "firehose_messages"

    belongs_to :channel,
      counter_cache: :messages_count
  end
end
