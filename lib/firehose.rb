# Firehose: WebSocket and SSE streaming with database-backed replay
#
# Usage:
#   Firehose.broadcast("stream_name", "data")
#
# Controller:
#   class CableController < ApplicationController
#     include Firehose::Stream
#   end
#
# Configuration:
#   Firehose.cleanup_threshold = 100  # messages per stream before cleanup
#
module Firehose
  VERSION = "2.0.0"

  mattr_accessor :cleanup_threshold, default: 100

  class << self
    def broadcast(stream, data)
      Broadcaster.broadcast(stream, data)
    end
  end
end

require_relative "firehose/engine"
require_relative "firehose/event"
require_relative "firehose/broadcaster"
require_relative "firehose/cleanup_job"
require_relative "firehose/streamable"
require_relative "firehose/websocket"
require_relative "firehose/sse"
require_relative "firehose/stream"
require_relative "firehose/helper"
