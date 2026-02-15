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

  class << self
    def broadcast(stream, data)
      server.broadcast(stream, data)
    end

    def server
      @server || raise("Firehose::Server not started. Ensure the Firehose engine has initialized.")
    end

    def server=(server)
      @server = server
    end

    def logger
      @logger ||= defined?(Rails) ? Rails.logger : Logger.new($stdout, progname: "Firehose")
    end

    def logger=(logger)
      @logger = logger
    end
  end
end

require_relative "firehose/engine"
require_relative "firehose/channel"
require_relative "firehose/message"
require_relative "firehose/server"
require_relative "firehose/cleanup_job"
require_relative "firehose/streamable"
require_relative "firehose/websocket"
require_relative "firehose/sse"
require_relative "firehose/queue"
require_relative "firehose/stream"
require_relative "firehose/helper"
