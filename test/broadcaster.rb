require_relative "../../../config/environment"

describe Firehose::Broadcaster do
  it "creates an event in the database" do
    initial_count = Firehose::Event.count

    event = Firehose.broadcast("test-broadcast", "refresh")

    expect(Firehose::Event.count).to be == initial_count + 1
    expect(event.stream).to be == "test-broadcast"
    expect(event.data).to be == "refresh"
  end

  it "returns the created event" do
    event = Firehose.broadcast("return-test", "data")

    expect(event).to be_a(Firehose::Event)
    expect(event.persisted?).to be == true
  end

  it "converts stream and data to strings" do
    event = Firehose.broadcast(:symbol_stream, 12345)

    expect(event.stream).to be == "symbol_stream"
    expect(event.data).to be == "12345"
  end

  it "generates correct channel names" do
    expect(Firehose::Broadcaster.channel_name("test")).to be == "firehose:test"
    expect(Firehose::Broadcaster.channel_name("user:123")).to be == "firehose:user:123"
  end

  it "handles special characters in stream names" do
    event = Firehose.broadcast("stream/with:special-chars_123", "data")
    expect(event.stream).to be == "stream/with:special-chars_123"
  end

  it "handles GlobalID-style stream names" do
    stream = "Z2lkOi8vc2VydmVyL0luc2lnaHRzOjpSZXBvcnQvMTQ"
    event = Firehose.broadcast(stream, "refresh")
    expect(event.stream).to be == stream
  end

  with "pubsub integration" do
    it "broadcasts to ActionCable pubsub" do
      stream = "pubsub-test-#{SecureRandom.hex(4)}"
      channel = Firehose::Broadcaster.channel_name(stream)
      received = []

      callback = ->(message) {
        data = message.respond_to?(:data) ? message.data : message
        received << JSON.parse(data)
      }

      ActionCable.server.pubsub.subscribe(channel, callback)
      sleep 0.1 # Allow subscription to establish

      event = Firehose.broadcast(stream, "test-message")
      sleep 0.2 # Allow message to propagate

      ActionCable.server.pubsub.unsubscribe(channel, callback)

      expect(received.length).to be == 1
      expect(received.first["id"]).to be == event.id
      expect(received.first["stream"]).to be == stream
      expect(received.first["data"]).to be == "test-message"
    end
  end

  with "cleanup threshold" do
    before do
      @original_threshold = Firehose.cleanup_threshold
      Firehose.cleanup_threshold = 5
    end

    after do
      Firehose.cleanup_threshold = @original_threshold
    end

    it "does not trigger cleanup below threshold" do
      stream = "below-threshold-#{SecureRandom.hex(4)}"

      # Create 4 events (below threshold of 5)
      4.times { |i| Firehose.broadcast(stream, "event-#{i}") }

      expect(Firehose::Event.where(stream:).count).to be == 4
    end

    it "triggers cleanup when threshold exceeded" do
      stream = "cleanup-test-#{SecureRandom.hex(4)}"

      # Create events exceeding threshold
      6.times { |i| Firehose.broadcast(stream, "event-#{i}") }

      # Cleanup runs (inline in test mode), keeps threshold count
      expect(Firehose::Event.where(stream:).count).to be == 5
    end
  end

  with "concurrent broadcasts" do
    it "handles rapid sequential broadcasts" do
      stream = "rapid-#{SecureRandom.hex(4)}"

      events = 10.times.map { |i| Firehose.broadcast(stream, "msg-#{i}") }

      expect(events.length).to be == 10
      expect(events.map(&:id)).to be == events.map(&:id).sort
    end
  end
end
