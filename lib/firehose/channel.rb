module Firehose
  # Public API for interacting with a named stream.
  #
  #   channel = Firehose.channel("dashboard")
  #   channel.publish("refresh")
  #
  #   sub = channel.subscribe { |payload| puts payload }
  #   sub.close
  #
  class Channel
    attr_reader :name

    def initialize(name, server: Firehose.server)
      @name = name.to_s
      @server = server
    end

    def publish(data)
      @server.broadcast(@name, data)
    end

    def subscribe(&callback)
      pg_channel = @server.channel_name(@name)
      @server.subscribe(pg_channel, callback)
      Subscription.new(@server, pg_channel, callback)
    end

    class Subscription
      def initialize(server, channel, callback)
        @server = server
        @channel = channel
        @callback = callback
      end

      def close
        @server.unsubscribe(@channel, @callback)
      end
    end
  end
end
