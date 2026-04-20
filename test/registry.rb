require_relative "test_helper"

describe Firehose::Server::Registry do
  with "add / remove bookkeeping" do
    let(:registry) { Firehose::Server::Registry.new }

    it "reports first-add so the caller can issue LISTEN" do
      cb = ->(_) {}
      first = registry.add("ch", cb, channel_name: "ch-name")
      expect(first).to be == true
    end

    it "reports not-first on subsequent adds to the same channel" do
      cb1 = ->(_) {}
      cb2 = ->(_) {}
      registry.add("ch", cb1, channel_name: "ch-name")
      subsequent = registry.add("ch", cb2, channel_name: "ch-name")
      expect(subsequent).to be == false
    end

    it "reports last-remove so the caller can issue UNLISTEN" do
      cb = ->(_) {}
      registry.add("ch", cb, channel_name: "ch-name")
      last = registry.remove("ch", cb)
      expect(last).to be == true
    end

    it "remembers the channel name for replay lookups" do
      cb = ->(_) {}
      registry.add("hashed-id", cb, channel_name: "human-readable-channel")
      expect(registry.channel_name("hashed-id")).to be == "human-readable-channel"
    end
  end

  with "memory — registry drains to zero under churn" do
    # Without this property, every subscribe/unsubscribe cycle would
    # leak an entry in @channels or @names, and long-running processes
    # that churn subscribers (WebSocket reconnects, SSE page nav) would
    # grow memory without bound.
    it "has no residual entries after N subscribes + N unsubscribes" do
      registry = Firehose::Server::Registry.new

      1_000.times do |i|
        cb = ->(_) {}
        registry.add("hashed-#{i}", cb, channel_name: "stream-#{i}")
        registry.remove("hashed-#{i}", cb)
      end

      expect(registry.size).to be == 0
      expect(registry.instance_variable_get(:@channels).size).to be == 0
      expect(registry.instance_variable_get(:@names).size).to be == 0
    end

    it "cleans up a channel's @names entry only after the last callback leaves" do
      registry = Firehose::Server::Registry.new
      cb1 = ->(_) {}
      cb2 = ->(_) {}

      registry.add("ch", cb1, channel_name: "s")
      registry.add("ch", cb2, channel_name: "s")

      registry.remove("ch", cb1)
      expect(registry.channel_name("ch")).to be == "s"  # still there

      registry.remove("ch", cb2)
      expect(registry.channel_name("ch")).to be == nil  # gone
    end
  end

  with "callback iteration" do
    let(:registry) { Firehose::Server::Registry.new }

    it "invokes every callback when notify fires" do
      received = []
      a = ->(payload) { received << [:a, payload] }
      b = ->(payload) { received << [:b, payload] }

      registry.add("ch", a, channel_name: "s")
      registry.add("ch", b, channel_name: "s")

      registry.notify("ch", "hi")

      expect(received).to be(:include?, [:a, "hi"])
      expect(received).to be(:include?, [:b, "hi"])
    end

    it "isolates callback failures — one raiser doesn't block the others" do
      good = []
      raiser = ->(_) { raise "boom" }
      ok = ->(payload) { good << payload }

      registry.add("ch", raiser, channel_name: "s")
      registry.add("ch", ok, channel_name: "s")

      registry.notify("ch", "hello")
      expect(good).to be == ["hello"]
    end
  end
end
