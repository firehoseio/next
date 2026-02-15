require_relative "test_helper"

describe Firehose::Server do
  it "creates a message in the database" do
    initial_count = Firehose::Models::Message.count

    message = Firehose.channel("test-broadcast").publish("refresh")

    expect(Firehose::Models::Message.count).to be == initial_count + 1
    expect(message.channel.name).to be == "test-broadcast"
    expect(message.data).to be == "refresh"
  end

  it "returns the created message" do
    message = Firehose.channel("return-test").publish("data")

    expect(message).to be_a(Firehose::Models::Message)
    expect(message.persisted?).to be == true
  end

  it "converts stream and data to strings" do
    message = Firehose.channel(:symbol_stream).publish(12345)

    expect(message.channel.name).to be == "symbol_stream"
    expect(message.data).to be == "12345"
  end

  it "assigns monotonic sequences per channel" do
    channel = Firehose.channel("seq-test-#{SecureRandom.hex(4)}")
    m1 = channel.publish("first")
    m2 = channel.publish("second")
    m3 = channel.publish("third")

    expect(m1.sequence).to be == 1
    expect(m2.sequence).to be == 2
    expect(m3.sequence).to be == 3
  end

  it "maintains independent sequences per channel" do
    channel_a = Firehose.channel("seq-a-#{SecureRandom.hex(4)}")
    channel_b = Firehose.channel("seq-b-#{SecureRandom.hex(4)}")

    a1 = channel_a.publish("a1")
    b1 = channel_b.publish("b1")
    a2 = channel_a.publish("a2")

    expect(a1.sequence).to be == 1
    expect(b1.sequence).to be == 1
    expect(a2.sequence).to be == 2
  end

  it "generates correct channel names" do
    expect(Firehose.server.channel_name("test")).to be == "firehose:test"
    expect(Firehose.server.channel_name("user:123")).to be == "firehose:user:123"
  end

  it "handles special characters in stream names" do
    message = Firehose.channel("stream/with:special-chars_123").publish("data")
    expect(message.channel.name).to be == "stream/with:special-chars_123"
  end

  it "handles GlobalID-style stream names" do
    stream = "Z2lkOi8vc2VydmVyL0luc2lnaHRzOjpSZXBvcnQvMTQ"
    message = Firehose.channel(stream).publish("refresh")
    expect(message.channel.name).to be == stream
  end

  with "pubsub integration" do
    it "notifies subscribers with the full event" do
      stream = "pubsub-test-#{SecureRandom.hex(4)}"
      received = []

      sub = Firehose.channel(stream).subscribe { |payload| received << payload }
      sleep 0.1

      message = Firehose.channel(stream).publish("test-message")
      sleep 0.2

      sub.close

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

      4.times { |i| Firehose.channel(stream).publish("event-#{i}") }

      channel = Firehose::Models::Channel.find_by!(name: stream)
      expect(channel.messages.count).to be == 4
    end

    it "triggers cleanup when threshold exceeded" do
      stream = "cleanup-test-#{SecureRandom.hex(4)}"

      6.times { |i| Firehose.channel(stream).publish("event-#{i}") }

      # CleanupJob runs async via GoodJob — invoke directly to verify behavior
      Firehose::CleanupJob.perform_now(stream)

      channel = Firehose::Models::Channel.find_by!(name: stream)
      expect(channel.messages.count).to be == 5
    end
  end

  with "concurrent broadcasts" do
    it "handles rapid sequential broadcasts" do
      channel = Firehose.channel("rapid-#{SecureRandom.hex(4)}")

      messages = 10.times.map { |i| channel.publish("msg-#{i}") }

      expect(messages.length).to be == 10
      expect(messages.map(&:id)).to be == messages.map(&:id).sort
      expect(messages.map(&:sequence)).to be == (1..10).to_a
    end
  end
end
