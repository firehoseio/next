module Firehose
  module Models
    class Message < ActiveRecord::Base
      self.table_name = "firehose_messages"

      belongs_to :channel,
        class_name: "Firehose::Models::Channel",
        counter_cache: :messages_count
    end
  end
end
