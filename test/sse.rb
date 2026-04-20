require_relative "test_helper"

# A minimal body double that records what the SSE handler writes.
class RecordingBody
  attr_reader :chunks

  def initialize
    @chunks = []
  end

  def write(chunk)
    @chunks << chunk
  end

  def to_s
    @chunks.join
  end
end

class RecordingResponse
  attr_reader :body

  def initialize
    @body = RecordingBody.new
  end
end

class StubRequest
  def initialize(headers: {})
    @headers = headers
  end

  attr_reader :headers
end

# Minimal controller stand-in — supplies the Streamable hooks.
class StubController
  def authorize_streams(streams) = streams
  def build_event(event) = event
end

describe Firehose::SSE::SSEHandler do
  let(:controller) { StubController.new }
  let(:request) { StubRequest.new(headers: {}) }
  let(:response) { RecordingResponse.new }

  with "write_event for a normal event" do
    it "writes SSE id, event, and data lines" do
      handler = Firehose::SSE::SSEHandler.new(request, response, streams: ["x"], controller: controller)
      handler.send(:write_event, id: 42, channel_id: 1, sequence: 3, stream: "x", data: "hello")

      output = response.body.to_s
      expect(output).to be(:include?, "id: 42\n")
      expect(output).to be(:include?, "event: x\n")
      expect(output).to be(:include?, "\"data\":\"hello\"")
      expect(output).to be(:include?, "\"sequence\":3")
      expect(output).to be(:include?, "\"channel_id\":1")
      expect(output).to be(:include?, "\n\n")  # SSE terminator
    end
  end

  with "write_event for an error event" do
    it "uses the firehose_<error> event name and omits the error key from data" do
      handler = Firehose::SSE::SSEHandler.new(request, response, streams: ["x"], controller: controller)
      handler.send(:write_event,
        error: "replay_gap",
        stream: "x",
        last_event_id: 10,
        oldest_retained_id: 50,
        current_id: 100
      )

      output = response.body.to_s
      expect(output).to be(:include?, "event: firehose_replay_gap\n")
      expect(output).to be(:include?, "\"stream\":\"x\"")
      expect(output).to be(:include?, "\"oldest_retained_id\":50")
      expect(output).not.to be(:include?, "\"error\":")  # error is in the event name, not the data
    end
  end

  with "write_event respects controller#build_event" do
    it "skips sending when build_event returns nil" do
      filtering = StubController.new
      filtering.define_singleton_method(:build_event) { |_| nil }

      handler = Firehose::SSE::SSEHandler.new(request, response, streams: ["x"], controller: filtering)
      handler.send(:write_event, id: 1, stream: "x", data: "dropped")

      expect(response.body.to_s).to be == ""
    end
  end

  with "last_event_id" do
    it "reads the Last-Event-ID header and coerces to integer" do
      request = StubRequest.new(headers: { "Last-Event-ID" => "42" })
      handler = Firehose::SSE::SSEHandler.new(request, response, streams: ["x"], controller: controller)
      expect(handler.send(:last_event_id)).to be == 42
    end

    it "returns 0 when the header is missing" do
      request = StubRequest.new(headers: {})
      handler = Firehose::SSE::SSEHandler.new(request, response, streams: ["x"], controller: controller)
      expect(handler.send(:last_event_id)).to be == 0
    end
  end

  with "replay_events" do
    let(:stream) { "sse-replay-#{SecureRandom.hex(4)}" }

    it "emits replay_gap when the cursor predates retention" do
      channel = Firehose::Models::Channel.create!(name: stream)
      channel.messages.create!(sequence: 1, data: "first")
      second = channel.messages.create!(sequence: 2, data: "second")

      # Client's cursor is non-zero but older than any retained message.
      stale_cursor = (channel.messages.minimum(:id) - 1).to_s

      request = StubRequest.new(headers: { "Last-Event-ID" => stale_cursor })
      handler = Firehose::SSE::SSEHandler.new(request, response, streams: [stream], controller: controller)
      handler.send(:replay_events)

      output = response.body.to_s
      expect(output).to be(:include?, "event: firehose_replay_gap\n")
      expect(output).to be(:include?, "\"oldest_retained_id\":#{channel.messages.minimum(:id)}")
      expect(output).to be(:include?, "\"current_id\":#{second.id}")
    end

    it "emits normal events when the cursor is within retention" do
      channel = Firehose::Models::Channel.create!(name: stream)
      first = channel.messages.create!(sequence: 1, data: "first")
      second = channel.messages.create!(sequence: 2, data: "second")

      request = StubRequest.new(headers: { "Last-Event-ID" => first.id.to_s })
      handler = Firehose::SSE::SSEHandler.new(request, response, streams: [stream], controller: controller)
      handler.send(:replay_events)

      output = response.body.to_s
      expect(output).not.to be(:include?, "firehose_replay_gap")
      expect(output).to be(:include?, "id: #{second.id}\n")
    end

    it "is a no-op when last_event_id is 0" do
      channel = Firehose::Models::Channel.create!(name: stream)
      channel.messages.create!(sequence: 1, data: "first")

      request = StubRequest.new(headers: {})
      handler = Firehose::SSE::SSEHandler.new(request, response, streams: [stream], controller: controller)
      handler.send(:replay_events)

      expect(response.body.to_s).to be == ""
    end
  end

  with "resolve_event" do
    let(:stream) { "sse-resolve-#{SecureRandom.hex(4)}" }

    it "fetches full event data from the DB when the payload lacks :data" do
      channel = Firehose::Models::Channel.create!(name: stream)
      msg = channel.messages.create!(sequence: 1, data: "heavy-payload")

      handler = Firehose::SSE::SSEHandler.new(request, response, streams: [stream], controller: controller)
      resolved = handler.send(:resolve_event, { id: msg.id })

      expect(resolved[:data]).to be == "heavy-payload"
      expect(resolved[:stream]).to be == stream
      expect(resolved[:sequence]).to be == 1
    end

    it "returns nil when the message has been cleaned up" do
      handler = Firehose::SSE::SSEHandler.new(request, response, streams: ["gone"], controller: controller)
      resolved = handler.send(:resolve_event, { id: 99_999_999 })
      expect(resolved).to be == nil
    end
  end
end
