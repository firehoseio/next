require_relative "test_helper"

describe Firehose::Server::NotifyPool do
  with "lifecycle" do
    let(:server) { Firehose::Server.new }

    it "starts size workers" do
      server.notify_pool_size = 3
      server.start
      server.subscribe("pool-#{SecureRandom.hex(4)}", ->(_) {})
      sleep 0.2

      pool = server.instance_variable_get(:@notify_pool)
      expect(pool.running?).to be == true
      threads = pool.instance_variable_get(:@threads)
      expect(threads.size).to be == 3
      expect(threads.all?(&:alive?)).to be == true
    ensure
      server&.shutdown
    end

    it "stops cleanly" do
      server.notify_pool_size = 2
      server.start
      server.subscribe("pool-stop-#{SecureRandom.hex(4)}", ->(_) {})
      sleep 0.2

      pool = server.instance_variable_get(:@notify_pool)
      expect(pool.running?).to be == true

      server.shutdown
      expect(pool.running?).to be == false
    end

    it "disables the pool when notify_pool_size = 0" do
      server.notify_pool_size = 0
      server.start
      server.subscribe("pool-off-#{SecureRandom.hex(4)}", ->(_) {})
      sleep 0.1

      expect(server.instance_variable_get(:@notify_pool)).to be == nil
    ensure
      server&.shutdown
    end
  end

  with "delivery end-to-end through the pool" do
    let(:stream) { "pool-delivery-#{SecureRandom.hex(4)}" }

    it "delivers broadcasts through worker threads to subscribers" do
      received = ::Queue.new
      Firehose.server.subscribe(Firehose.server.channel_name(stream), ->(payload) { received << payload })
      sleep 0.2  # let LISTEN settle

      Firehose.server.broadcast(stream, "via-pool")
      payload = received.pop(timeout: 3)

      parsed = JSON.parse(payload)
      expect(parsed["data"]).to be == "via-pool"
    end
  end
end
