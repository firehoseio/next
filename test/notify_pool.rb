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

    it "delivers a burst of broadcasts with no loss under load" do
      received = ::Queue.new
      Firehose.server.subscribe(Firehose.server.channel_name(stream), ->(payload) { received << payload })
      sleep 0.2

      burst = 50
      threads = (1..burst).map do |i|
        Thread.new { Firehose.server.broadcast(stream, "msg-#{i}") }
      end
      threads.each(&:join)

      collected = []
      burst.times { collected << received.pop(timeout: 5) }

      # Every broadcast must have been delivered; order can vary across
      # the pool but the ids must match what we wrote.
      delivered_ids = collected.map { |p| JSON.parse(p)["id"] }.sort
      wrote_ids = Firehose::Models::Message.where(channel: Firehose::Models::Channel.find_by!(name: stream)).pluck(:id).sort
      expect(delivered_ids.last(burst)).to be == wrote_ids.last(burst)
    end
  end

  with "failure recovery" do
    let(:server) { Firehose::Server.new }

    it "counts notify_failures when a worker's PG call raises" do
      server.notify_pool_size = 2
      server.start
      server.subscribe("fail-counter-#{SecureRandom.hex(4)}", ->(_) {})
      sleep 0.2

      pool = server.instance_variable_get(:@notify_pool)
      before = server.metrics_snapshot[:notify_failures]

      # Inject work that will blow up — the worker will rescue PG::Error,
      # reopen its connection, and continue.
      2.times do
        pool.enqueue("nonexistent-channel-id-with-bad-chars\x00raising", "payload")
      end

      # Give workers a moment to dequeue + fail + reopen.
      sleep 0.5

      after = server.metrics_snapshot[:notify_failures]
      expect(after).to be > before
      expect(pool.running?).to be == true  # pool survived
    ensure
      server&.shutdown
    end

    it "keeps other workers available when one worker's connection fails" do
      # Each worker owns its own conn. A failure on one must not affect the
      # others. This is an observational test: after forcing a failure on
      # every worker, the pool still delivers the next valid broadcast.
      server.notify_pool_size = 4
      server.start

      stream = "resilient-pool-#{SecureRandom.hex(4)}"
      pool = server.instance_variable_get(:@notify_pool)

      received = ::Queue.new
      server.subscribe(server.channel_name(stream), ->(payload) { received << payload })
      sleep 0.2

      # Fire bad payloads to exercise worker failure paths.
      4.times { pool.enqueue("\x00bogus", "bad") }
      sleep 0.3

      # Now broadcast legitimately — should still deliver.
      server.broadcast(stream, "after-failure")
      payload = received.pop(timeout: 3)
      expect(payload).not.to be == nil
      expect(JSON.parse(payload)["data"]).to be == "after-failure"
    ensure
      server&.shutdown
    end
  end
end
