module Firehose
  class Event < ActiveRecord::Base
    self.table_name = "firehose_events"
  end
end
