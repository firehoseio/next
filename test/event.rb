require_relative "../../../config/environment"

describe Firehose::Event do
  it "creates events with stream and data" do
    event = Firehose::Event.create!(stream: "test", data: "hello")

    expect(event.id).to be_a(Integer)
    expect(event.stream).to be == "test"
    expect(event.data).to be == "hello"
    expect(event.created_at).to be_a(Time)
  end

  it "persists events to the database" do
    event = Firehose::Event.create!(stream: "persist-test", data: "world")

    found = Firehose::Event.find(event.id)
    expect(found.stream).to be == "persist-test"
    expect(found.data).to be == "world"
  end

  it "auto-generates created_at timestamp" do
    before = Time.current
    event = Firehose::Event.create!(stream: "timestamp-test", data: "data")
    after = Time.current

    expect(event.created_at).to be >= before
    expect(event.created_at).to be <= after
  end

  it "assigns sequential IDs" do
    e1 = Firehose::Event.create!(stream: "seq-test", data: "first")
    e2 = Firehose::Event.create!(stream: "seq-test", data: "second")

    expect(e2.id).to be > e1.id
  end

  it "requires stream to be present" do
    expect { Firehose::Event.create!(stream: nil, data: "data") }.to raise_exception(ActiveRecord::NotNullViolation)
  end

  it "requires data to be present" do
    expect { Firehose::Event.create!(stream: "test", data: nil) }.to raise_exception(ActiveRecord::NotNullViolation)
  end

  it "handles empty string data" do
    event = Firehose::Event.create!(stream: "empty-test", data: "")
    expect(event.data).to be == ""
  end

  it "handles unicode data" do
    event = Firehose::Event.create!(stream: "unicode-test", data: "Hello 🌍 世界")
    found = Firehose::Event.find(event.id)
    expect(found.data).to be == "Hello 🌍 世界"
  end

  it "handles JSON data" do
    json_data = { action: "refresh", payload: { id: 123 } }.to_json
    event = Firehose::Event.create!(stream: "json-test", data: json_data)

    found = Firehose::Event.find(event.id)
    parsed = JSON.parse(found.data)
    expect(parsed["action"]).to be == "refresh"
  end

  with "multiple streams" do
    let(:stream_a) { "stream-a-#{SecureRandom.hex(4)}" }
    let(:stream_b) { "stream-b-#{SecureRandom.hex(4)}" }

    before do
      Firehose::Event.create!(stream: stream_a, data: "a1")
      Firehose::Event.create!(stream: stream_a, data: "a2")
      Firehose::Event.create!(stream: stream_b, data: "b1")
    end

    it "filters by stream" do
      events = Firehose::Event.where(stream: stream_a)
      expect(events.count).to be == 2
    end

    it "filters by multiple streams" do
      events = Firehose::Event.where(stream: [stream_a, stream_b])
      expect(events.count).to be == 3
    end

    it "orders by ID ascending" do
      events = Firehose::Event.where(stream: stream_a).order(:id)
      expect(events.first.data).to be == "a1"
      expect(events.last.data).to be == "a2"
    end
  end

  with "replay queries" do
    let(:stream) { "replay-#{SecureRandom.hex(4)}" }

    def create_events(stream)
      5.times.map { |i| Firehose::Event.create!(stream:, data: "event-#{i}") }
    end

    it "fetches events after a given ID" do
      events = create_events(stream)
      since_id = events[1].id
      result = Firehose::Event.where(stream:).where("id > ?", since_id).order(:id)

      expect(result.count).to be == 3
      expect(result.first.data).to be == "event-2"
    end

    it "returns empty when no events after ID" do
      events = create_events(stream)
      since_id = events.last.id
      result = Firehose::Event.where(stream:).where("id > ?", since_id)

      expect(result.count).to be == 0
    end

    it "returns all events when since_id is 0" do
      create_events(stream)
      result = Firehose::Event.where(stream:).where("id > ?", 0).order(:id)
      expect(result.count).to be == 5
    end
  end
end
