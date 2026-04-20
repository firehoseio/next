require_relative "test_helper"

# Fake WS connection that records writes + lets us inject receive_pong.
class StubConnection
  attr_reader :writes, :pings, :closed

  def initialize
    @writes = []
    @pings = 0
    @closed = false
  end

  def write(message) = @writes << message
  def flush = nil
  def send_ping = @pings += 1

  def close
    @closed = true
  end

  # Allow tests to trigger a pong frame.
  def deliver_pong(handler)
    receive_pong(nil)
  end
end

class StubController
  def authorize_streams(streams) = streams
  def build_event(event) = event
end

describe Firehose::WebSocket::WebSocketHandler do
  let(:controller) { StubController.new }
  let(:connection) { StubConnection.new }
  let(:handler) { Firehose::WebSocket::WebSocketHandler.new(connection, controller: controller) }

  with "pong tracker installation" do
    it "installs receive_pong on the connection" do
      # Before handler construction, StubConnection has no receive_pong.
      expect(connection.respond_to?(:receive_pong)).to be == false

      handler  # triggers install_pong_tracker in initialize
      expect(connection.respond_to?(:receive_pong)).to be == true
    end

    it "updates @last_pong_at when the connection receives a pong" do
      handler
      before = handler.instance_variable_get(:@last_pong_at)
      sleep 0.01  # ensure monotonic clock advances
      connection.receive_pong(nil)
      after = handler.instance_variable_get(:@last_pong_at)

      expect(after).to be > before
    end
  end

  with "enqueue_or_disconnect" do
    it "enqueues when the queue is under limit" do
      queue = handler.instance_variable_get(:@queue)
      handler.send(:enqueue_or_disconnect, "payload-1")
      expect(queue.size).to be == 1
    end

    it "disconnects once when the queue reaches the limit" do
      queue = handler.instance_variable_get(:@queue)
      limit = handler.instance_variable_get(:@queue_limit)
      # Fill the queue to the cap.
      limit.times { |i| queue.enqueue("payload-#{i}") }

      handler.send(:enqueue_or_disconnect, "overflow")
      expect(connection.closed).to be == true

      # Second overflow in the same handler should not re-close or spam logs.
      handler.send(:enqueue_or_disconnect, "overflow-again")
      expect(handler.instance_variable_get(:@overflow)).to be == true
    end

    it "does not enqueue the overflow payload" do
      queue = handler.instance_variable_get(:@queue)
      limit = handler.instance_variable_get(:@queue_limit)
      limit.times { |i| queue.enqueue("payload-#{i}") }
      size_before = queue.size

      handler.send(:enqueue_or_disconnect, "dropped")
      expect(queue.size).to be == size_before  # no growth past the limit
    end
  end

  with "protocol ping interval constant" do
    it "is less than the pong timeout so a missed pong catches within bounded windows" do
      expect(Firehose::WebSocket::PING_INTERVAL).to be < Firehose::WebSocket::PONG_TIMEOUT
    end

    it "has a pong timeout that tolerates at least two missed pings" do
      # 90/30 == 3 pings' worth of window, which is the minimum that tolerates
      # a single dropped ping without a false positive disconnect.
      ratio = Firehose::WebSocket::PONG_TIMEOUT.to_f / Firehose::WebSocket::PING_INTERVAL
      expect(ratio).to be >= 2
    end
  end

  with "replay_events emits replay_gap for stale cursor" do
    let(:stream) { "ws-replay-#{SecureRandom.hex(4)}" }

    it "sends a replay_gap JSON frame when cursor predates retention" do
      channel = Firehose::Models::Channel.create!(name: stream)
      channel.messages.create!(sequence: 1, data: "a")
      channel.messages.create!(sequence: 2, data: "b")
      stale_cursor = channel.messages.minimum(:id) - 1

      handler.send(:replay_events, [stream], stale_cursor)

      frames = connection.writes.map(&:to_str).map { |s| JSON.parse(s, symbolize_names: true) }
      gap = frames.find { |f| f[:error] == "replay_gap" }
      expect(gap).not.to be == nil
      expect(gap[:stream]).to be == stream
      expect(gap[:oldest_retained_id]).to be == channel.messages.minimum(:id)
    end

    it "sends normal events when cursor is within retention" do
      channel = Firehose::Models::Channel.create!(name: stream)
      first = channel.messages.create!(sequence: 1, data: "a")
      second = channel.messages.create!(sequence: 2, data: "b")

      handler.send(:replay_events, [stream], first.id)

      frames = connection.writes.map(&:to_str).map { |s| JSON.parse(s, symbolize_names: true) }
      expect(frames.any? { |f| f[:error] == "replay_gap" }).to be == false
      expect(frames.map { |f| f[:id] }.compact).to be == [second.id]
    end

    it "handles per-stream gap — gappy stream gets error, healthy stream gets data" do
      # Create healthy FIRST so its ids are smaller than gappy's.
      healthy = "ws-healthy-#{SecureRandom.hex(4)}"
      healthy_ch = Firehose::Models::Channel.create!(name: healthy)
      h1 = healthy_ch.messages.create!(sequence: 1, data: "h1")
      h2 = healthy_ch.messages.create!(sequence: 2, data: "h2")

      gappy = "ws-gappy-#{SecureRandom.hex(4)}"
      gappy_ch = Firehose::Models::Channel.create!(name: gappy)
      g1 = gappy_ch.messages.create!(sequence: 1, data: "g1")
      g2 = gappy_ch.messages.create!(sequence: 2, data: "g2")

      # Simulate retention having already pruned older gappy messages:
      # delete g1 so gappy's oldest is g2, well above h1's id.
      g1.destroy!

      # Cursor between h1 and g2 → healthy has a normal gap (replay h2),
      # gappy's retention begins past the cursor (emit replay_gap).
      cursor = h1.id

      handler.send(:replay_events, [gappy, healthy], cursor)

      frames = connection.writes.map(&:to_str).map { |s| JSON.parse(s, symbolize_names: true) }
      gap_frames = frames.select { |f| f[:error] == "replay_gap" }
      expect(gap_frames.map { |f| f[:stream] }).to be == [gappy]

      replayed_ids = frames.select { |f| f[:stream] == healthy && f[:error].nil? }.map { |f| f[:id] }
      expect(replayed_ids).to be == [h2.id]
    end
  end
end
