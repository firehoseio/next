require_relative "../../../config/environment"

describe Firehose::Server do
  it "creates a message in the database" do
    initial_count = Firehose::Message.count

    message = Firehose.broadcast("test-broadcast", "refresh")

    expect(Firehose::Message.count).to be == initial_count + 1
    expect(message.channel.name).to be == "test-broadcast"
    expect(message.data).to be == "refresh"
  end

  it "returns the created message" do
    message = Firehose.broadcast("return-test", "data")

    expect(message).to be_a(Firehose::Message)
    expect(message.persisted?).to be == true
  end

  it "converts stream and data to strings" do
    message = Firehose.broadcast(:symbol_stream, 12345)

    expect(message.channel.name).to be == "symbol_stream"
    expect(message.data).to be == "12345"
  end

  it "assigns monotonic sequences per channel" do
    stream = "seq-test-#{SecureRandom.hex(4)}"
    m1 = Firehose.broadcast(stream, "first")
    m2 = Firehose.broadcast(stream, "second")
    m3 = Firehose.broadcast(stream, "third")

    expect(m1.sequence).to be == 1
    expect(m2.sequence).to be == 2
    expect(m3.sequence).to be == 3
  end

  it "maintains independent sequences per channel" do
    stream_a = "seq-a-#{SecureRandom.hex(4)}"
    stream_b = "seq-b-#{SecureRandom.hex(4)}"

    a1 = Firehose.broadcast(stream_a, "a1")
    b1 = Firehose.broadcast(stream_b, "b1")
    a2 = Firehose.broadcast(stream_a, "a2")

    expect(a1.sequence).to be == 1
    expect(b1.sequence).to be == 1
    expect(a2.sequence).to be == 2
  end

  it "generates correct channel names" do
    expect(Firehose.server.channel_name("test")).to be == "firehose:test"
    expect(Firehose.server.channel_name("user:123")).to be == "firehose:user:123"
  end

  it "handles special characters in stream names" do
    message = Firehose.broadcast("stream/with:special-chars_123", "data")
    expect(message.channel.name).to be == "stream/with:special-chars_123"
  end

  it "handles GlobalID-style stream names" do
    stream = "Z2lkOi8vc2VydmVyL0luc2lnaHRzOjpSZXBvcnQvMTQ"
    message = Firehose.broadcast(stream, "refresh")
    expect(message.channel.name).to be == stream
  end

  with "pubsub integration" do
    it "notifies subscribers with the full event" do
      stream = "pubsub-test-#{SecureRandom.hex(4)}"
      channel = Firehose.server.channel_name(stream)
      received = []

      callback = ->(payload) { received << payload }

      Firehose.server.subscribe(channel, callback)
      sleep 0.1

      message = Firehose.broadcast(stream, "test-message")
      sleep 0.2

      Firehose.server.unsubscribe(channel, callback)

      expect(received.length).to be == 1

      event = JSON.parse(received.first, symbolize_names: true)
      expect(event[:id]).to be == message.id
      expect(event[:sequence]).to be == message.sequence
      expect(event[:stream]).to be == stream
      expect(event[:data]).to be == "test-message"
    end
  end

  with "cleanup threshold" do
    before do
      @original_threshold = Firehose.server.cleanup_threshold
      Firehose.server.cleanup_threshold = 5
    end

    after do
      Firehose.server.cleanup_threshold = @original_threshold
    end

    it "does not trigger cleanup below threshold" do
      stream = "below-threshold-#{SecureRandom.hex(4)}"

      4.times { |i| Firehose.broadcast(stream, "event-#{i}") }

      channel = Firehose::Channel.find_by!(name: stream)
      expect(channel.messages.count).to be == 4
    end

    it "triggers cleanup when threshold exceeded" do
      stream = "cleanup-test-#{SecureRandom.hex(4)}"

      6.times { |i| Firehose.broadcast(stream, "event-#{i}") }

      # CleanupJob runs async via GoodJob — invoke directly to verify behavior
      Firehose::CleanupJob.perform_now(stream)

      channel = Firehose::Channel.find_by!(name: stream)
      expect(channel.messages.count).to be == 5
    end
  end

  with "concurrent broadcasts" do
    it "handles rapid sequential broadcasts" do
      stream = "rapid-#{SecureRandom.hex(4)}"

      messages = 10.times.map { |i| Firehose.broadcast(stream, "msg-#{i}") }

      expect(messages.length).to be == 10
      expect(messages.map(&:id)).to be == messages.map(&:id).sort
      expect(messages.map(&:sequence)).to be == (1..10).to_a
    end
  end
end
