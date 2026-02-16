# Firehose: WebSocket and SSE streaming with database-backed replay
#
# Usage:
#   Firehose.channel("dashboard").publish("refresh")
#
#   sub = Firehose.channel("dashboard").subscribe { |event| puts event }
#   sub.close
#
# Controller:
#   class FirehoseController < ApplicationController
#     include Firehose::Stream
#   end
#
module Firehose
  VERSION = "2.0.0"

  module Models
    autoload :Channel, "firehose/models/channel"
    autoload :Message, "firehose/models/message"
  end

  class << self
    def channel(name)
      Channel.new(name, server:)
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
require_relative "firehose/server"
require_relative "firehose/cleanup_job"
require_relative "firehose/streamable"
require_relative "firehose/websocket"
require_relative "firehose/sse"
require_relative "firehose/queue"
require_relative "firehose/stream"
require_relative "firehose/helper" if defined?(Phlex)
