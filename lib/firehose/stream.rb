module Firehose
  # Include both WebSocket and SSE transports.
  #
  # Usage:
  #   class CableController < ApplicationController
  #     include Firehose::Stream
  #
  #     before_action :authenticate_user!
  #
  #     def authorize_streams(streams)
  #       streams.select { |s| current_user.can_access?(s) }
  #     end
  #
  #     def build_event(event)
  #       event  # or transform/filter
  #     end
  #   end
  #
  # Routes:
  #   match "cable", to: "cable#websocket", via: [:get, :connect]
  #   get "cable/sse", to: "cable#sse"
  #
  # Or include just one transport:
  #   include Firehose::WebSocket
  #   include Firehose::SSE
  #
  module Stream
    extend ActiveSupport::Concern
    include WebSocket
    include SSE
  end
end
