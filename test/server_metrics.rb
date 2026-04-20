require_relative "test_helper"

describe Firehose::Server do
  with "metrics_snapshot" do
    let(:server) { Firehose::Server.new }

    it "returns a flat hash of gauges and counters" do
      snap = server.metrics_snapshot

      expect(snap).to be_a(Hash)
      expect(snap.key?(:command_queue_depth)).to be == true
      expect(snap.key?(:subscribed_channels)).to be == true
      expect(snap.key?(:seconds_since_heartbeat)).to be == true
      expect(snap.key?(:thread_alive)).to be == true
      expect(snap.key?(:reconnects_current)).to be == true
    end

    it "reports thread_alive as 0 when no thread is running" do
      expect(server.metrics_snapshot[:thread_alive]).to be == 0
    end

    it "counts broadcasts as they happen" do
      stream = "metrics-#{SecureRandom.hex(4)}"
      baseline = Firehose.server.metrics_snapshot[:broadcasts_total]

      Firehose.server.broadcast(stream, "hello")
      Firehose.server.broadcast(stream, "world")

      after = Firehose.server.metrics_snapshot[:broadcasts_total]
      expect(after - baseline).to be == 2
    end
  end

  with "on_metrics hook" do
    let(:server) { Firehose::Server.new }

    it "calls the hook periodically when configured" do
      received = []
      original = Firehose.on_metrics
      Firehose.on_metrics = ->(metrics) { received << metrics }

      server.metrics_interval = 0.1
      server.start
      server.subscribe("metrics-hook-#{SecureRandom.hex(4)}", ->(_) {})
      sleep 0.4  # 3-4 ticks

      expect(received.size).to be > 1
      expect(received.first).to be_a(Hash)
      expect(received.first[:subscribed_channels]).to be >= 1
    ensure
      Firehose.on_metrics = original
      server&.shutdown
    end

    it "swallows exceptions raised by the user-supplied reporter" do
      original = Firehose.on_metrics
      Firehose.on_metrics = ->(_) { raise "reporter exploded" }

      server.metrics_interval = 0.1
      server.start
      server.subscribe("metrics-raise-#{SecureRandom.hex(4)}", ->(_) {})
      sleep 0.3

      emitter = server.instance_variable_get(:@metrics_emitter)
      expect(emitter.alive?).to be == true
    ensure
      Firehose.on_metrics = original
      server&.shutdown
    end

    it "does not start the emitter when on_metrics is not configured" do
      original = Firehose.on_metrics
      Firehose.on_metrics = nil

      server.start
      server.subscribe("metrics-off-#{SecureRandom.hex(4)}", ->(_) {})
      sleep 0.1

      expect(server.instance_variable_get(:@metrics_emitter)).to be == nil
    ensure
      Firehose.on_metrics = original
      server&.shutdown
    end
  end
end
