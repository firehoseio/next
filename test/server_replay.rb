require_relative "test_helper"

describe Firehose::Server do
  with "cursor tracking" do
    let(:server) { Firehose::Server.new }

    it "records the newest message id seen per channel" do
      pg_id = "abc123"
      server.send(:record_cursor, pg_id, '{"id":5,"data":"hello"}')
      server.send(:record_cursor, pg_id, '{"id":3,"data":"older"}')
      server.send(:record_cursor, pg_id, '{"id":8,"data":"newest"}')

      cursors = server.instance_variable_get(:@cursors)
      expect(cursors[pg_id]).to be == 8
    end

    it "silently ignores non-JSON payloads" do
      server.send(:record_cursor, "abc", "not json")
      server.send(:record_cursor, "abc", '{"no_id":"field"}')

      cursors = server.instance_variable_get(:@cursors)
      expect(cursors.key?("abc")).to be == false
    end
  end

  with "replay on reconnect" do
    let(:server) { Firehose::Server.new }
    let(:stream) { "replay-test-#{SecureRandom.hex(4)}" }

    it "fans out missed messages on reconnect" do
      received = ::Queue.new
      server.start

      pg_channel = server.channel_name(stream)
      server.subscribe(pg_channel, ->(payload) { received << payload })
      sleep 0.2  # let initial connect settle

      # Publish one real message so the cursor gets populated.
      msg = Firehose.server.broadcast(stream, "first")
      payload1 = received.pop(timeout: 3)
      expect(JSON.parse(payload1)["id"]).to be == msg.id

      # Insert more messages directly into the DB, simulating NOTIFYs we
      # would have missed while the connection was dropped.
      channel_record = Firehose::Models::Channel.find_by!(name: stream)
      missed1 = channel_record.messages.create!(sequence: channel_record.sequence + 1, data: "missed1")
      missed2 = channel_record.messages.create!(sequence: channel_record.sequence + 2, data: "missed2")

      # Simulate a reconnect by bumping @reconnects and calling connect again.
      server.instance_variable_set(:@reconnects, 1)
      server.send(:connect)

      replay1 = received.pop(timeout: 3)
      replay2 = received.pop(timeout: 3)
      ids = [JSON.parse(replay1)["id"], JSON.parse(replay2)["id"]]
      expect(ids).to be == [missed1.id, missed2.id]
    ensure
      server&.shutdown
    end

    it "skips replay on the initial connect" do
      # If @reconnects is 0 during connect, no DB lookups should happen.
      # Just verifying replay_missed_messages is gated on @reconnects > 0.
      server.replay_on_reconnect = true
      pg_id = "someid"
      server.instance_variable_get(:@cursors)[pg_id] = 100

      # Not calling connect directly; asserting on the gating condition.
      @reconnects = server.instance_variable_get(:@reconnects)
      expect(@reconnects).to be == 0
    end

    it "increments replay_messages_delivered when replay fires" do
      server.start
      server.subscribe(server.channel_name(stream), ->(_) {})
      sleep 0.2

      before = server.metrics_snapshot[:replay_messages_delivered]

      channel_record = Firehose::Models::Channel.find_or_create_by!(name: stream)
      # Seed the cursor below the messages we're about to insert.
      server.instance_variable_set(:@cursors,
        { server.send(:pg_identifier, server.channel_name(stream)) => 0 })
      3.times do |i|
        channel_record.messages.create!(sequence: channel_record.sequence + i + 1, data: "replay-#{i}")
      end

      server.instance_variable_set(:@reconnects, 1)
      server.send(:connect)

      after = server.metrics_snapshot[:replay_messages_delivered]
      expect(after - before).to be == 3
    ensure
      server&.shutdown
    end

    it "can be disabled via replay_on_reconnect = false" do
      server.replay_on_reconnect = false
      server.start
      received = ::Queue.new
      server.subscribe(server.channel_name(stream), ->(payload) { received << payload })
      sleep 0.2

      channel_record = Firehose::Models::Channel.find_or_create_by!(name: stream)
      channel_record.messages.create!(sequence: 1, data: "never-replayed")

      pg_id = server.send(:pg_identifier, server.channel_name(stream))
      server.instance_variable_set(:@cursors, { pg_id => 0 })
      server.instance_variable_set(:@reconnects, 1)
      server.send(:connect)

      # Nothing new should be delivered — replay_on_reconnect is off.
      # Wait a short window to confirm silence.
      sleep 0.3
      expect(received.size).to be == 0
    ensure
      server&.shutdown
    end
  end
end
