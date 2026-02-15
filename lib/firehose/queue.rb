module Firehose
  # Raw push/pop queue over PG LISTEN/NOTIFY.
  #
  # For ephemeral signaling (auth nonces, job completion, etc.) where
  # messages don't need database persistence or replay.
  #
  # For database-backed stream consumption with replay and ordering,
  # use Server::Subscriptions with the SSE or WebSocket transports.
  class Queue
    class TimeoutError < StandardError; end

    def initialize(channel, server: Firehose.server)
      @channel = channel
      @server = server
      @queue = ::Queue.new
      @callback = ->(payload) { @queue << payload }
      @subscribed = false
    end

    def subscribe
      return self if @subscribed
      @subscribed = true
      @server.subscribe(@channel, @callback)
      self
    end

    def push(message)
      @server.notify(@channel, message)
    end

    def pop(timeout: nil)
      subscribe
      payload = @queue.pop(timeout:)
      raise TimeoutError, "No message received on #{@channel} within #{timeout}s" if payload.nil? && timeout
      payload
    end

    def close
      @server.unsubscribe(@channel, @callback) if @subscribed
      @subscribed = false
      @queue.close
    end
  end
end
