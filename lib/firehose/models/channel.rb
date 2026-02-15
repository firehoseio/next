module Firehose
  module Models
    class Channel < ActiveRecord::Base
      self.table_name = "firehose_channels"

      has_many :messages,
        class_name: "Firehose::Models::Message",
        foreign_key: :channel_id,
        dependent: :delete_all
    end
  end
end
