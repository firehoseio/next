module Firehose
  class Channel < ActiveRecord::Base
    self.table_name = "firehose_channels"

    has_many :messages,
      dependent: :delete_all
  end
end
