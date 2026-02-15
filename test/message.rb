require_relative "test_helper"

describe Firehose::Channel do
  it "creates channels with name" do
    name = "test-channel-#{SecureRandom.hex(4)}"
    channel = Firehose::Channel.create!(name:)

    expect(channel.id).to be_a(Integer)
    expect(channel.name).to be == name
    expect(channel.sequence).to be == 0
    expect(channel.messages_count).to be == 0
  end

  it "enforces unique channel names" do
    name = "unique-test-#{SecureRandom.hex(4)}"
    Firehose::Channel.create!(name:)

    expect { Firehose::Channel.create!(name:) }.to raise_exception(ActiveRecord::RecordNotUnique)
  end

  it "cascades deletes to messages" do
    channel = Firehose::Channel.create!(name: "cascade-#{SecureRandom.hex(4)}")
    channel.messages.create!(sequence: 1, data: "msg1")
    channel.messages.create!(sequence: 2, data: "msg2")

    expect(Firehose::Message.where(channel_id: channel.id).count).to be == 2

    channel.destroy

    expect(Firehose::Message.where(channel_id: channel.id).count).to be == 0
  end
end

describe Firehose::Message do
  let(:channel) { Firehose::Channel.create!(name: "msg-test-#{SecureRandom.hex(4)}") }

  it "creates messages with channel, sequence, and data" do
    message = channel.messages.create!(sequence: 1, data: "hello")

    expect(message.id).to be_a(Integer)
    expect(message.channel_id).to be == channel.id
    expect(message.sequence).to be == 1
    expect(message.data).to be == "hello"
    expect(message.created_at).to be_a(Time)
  end

  it "persists messages to the database" do
    message = channel.messages.create!(sequence: 1, data: "world")

    found = Firehose::Message.find(message.id)
    expect(found.data).to be == "world"
    expect(found.channel_id).to be == channel.id
  end

  it "auto-generates created_at timestamp" do
    before = Time.current
    message = channel.messages.create!(sequence: 1, data: "data")
    after = Time.current

    expect(message.created_at).to be >= before
    expect(message.created_at).to be <= after
  end

  it "assigns sequential IDs" do
    m1 = channel.messages.create!(sequence: 1, data: "first")
    m2 = channel.messages.create!(sequence: 2, data: "second")

    expect(m2.id).to be > m1.id
  end

  it "enforces unique sequence per channel" do
    channel.messages.create!(sequence: 1, data: "first")

    expect { channel.messages.create!(sequence: 1, data: "dupe") }.to raise_exception(ActiveRecord::RecordNotUnique)
  end

  it "allows same sequence in different channels" do
    other = Firehose::Channel.create!(name: "other-#{SecureRandom.hex(4)}")

    m1 = channel.messages.create!(sequence: 1, data: "a")
    m2 = other.messages.create!(sequence: 1, data: "b")

    expect(m1.sequence).to be == m2.sequence
    expect(m1.channel_id).not.to be == m2.channel_id
  end

  it "requires data to be present" do
    expect { channel.messages.create!(sequence: 1, data: nil) }.to raise_exception(ActiveRecord::NotNullViolation)
  end

  it "handles empty string data" do
    message = channel.messages.create!(sequence: 1, data: "")
    expect(message.data).to be == ""
  end

  it "handles unicode data" do
    message = channel.messages.create!(sequence: 1, data: "Hello 🌍 世界")
    found = Firehose::Message.find(message.id)
    expect(found.data).to be == "Hello 🌍 世界"
  end

  it "handles JSON data" do
    json_data = { action: "refresh", payload: { id: 123 } }.to_json
    message = channel.messages.create!(sequence: 1, data: json_data)

    found = Firehose::Message.find(message.id)
    parsed = JSON.parse(found.data)
    expect(parsed["action"]).to be == "refresh"
  end

  with "multiple channels" do
    let(:channel_a) { Firehose::Channel.create!(name: "stream-a-#{SecureRandom.hex(4)}") }
    let(:channel_b) { Firehose::Channel.create!(name: "stream-b-#{SecureRandom.hex(4)}") }

    before do
      channel_a.messages.create!(sequence: 1, data: "a1")
      channel_a.messages.create!(sequence: 2, data: "a2")
      channel_b.messages.create!(sequence: 1, data: "b1")
    end

    it "filters by channel" do
      messages = Firehose::Message.where(channel_id: channel_a.id)
      expect(messages.count).to be == 2
    end

    it "filters by multiple channels" do
      messages = Firehose::Message.where(channel_id: [channel_a.id, channel_b.id])
      expect(messages.count).to be == 3
    end

    it "orders by ID ascending" do
      messages = Firehose::Message.where(channel_id: channel_a.id).order(:id)
      expect(messages.first.data).to be == "a1"
      expect(messages.last.data).to be == "a2"
    end
  end

  with "replay queries" do
    def create_messages(channel)
      5.times.map { |i|
        channel.update_columns(sequence: i + 1)
        channel.messages.create!(sequence: i + 1, data: "event-#{i}")
      }
    end

    it "fetches messages after a given ID" do
      messages = create_messages(channel)
      since_id = messages[1].id
      result = Firehose::Message.where(channel_id: channel.id).where("id > ?", since_id).order(:id)

      expect(result.count).to be == 3
      expect(result.first.data).to be == "event-2"
    end

    it "returns empty when no messages after ID" do
      messages = create_messages(channel)
      since_id = messages.last.id
      result = Firehose::Message.where(channel_id: channel.id).where("id > ?", since_id)

      expect(result.count).to be == 0
    end

    it "returns all messages when since_id is 0" do
      create_messages(channel)
      result = Firehose::Message.where(channel_id: channel.id).where("id > ?", 0).order(:id)
      expect(result.count).to be == 5
    end
  end
end
