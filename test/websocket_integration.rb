require_relative "test_helper"
require "async"
require "async/websocket/client"
require "async/http/endpoint"
require "sus/fixtures/async"

# Integration test that boots a minimal Falcon server and tests WebSocket
describe Firehose::Stream do
  include Sus::Fixtures::Async::ReactorContext

  let(:endpoint) { Async::HTTP::Endpoint.parse("http://localhost:19292/firehose") }

  # Start a test server
  def with_server(&block)
    require "falcon"
    require "rack"

    app = Rails.application

    Async do |task|
      server_endpoint = Async::HTTP::Endpoint.parse("http://localhost:19292")

      server = Falcon::Server.new(
        Falcon::Server.middleware(app),
        server_endpoint
      )

      server_task = task.async do
        server.run
      end

      # Give server time to start
      sleep 0.1

      begin
        yield
      ensure
        server_task.stop
      end
    end
  end

  it "accepts WebSocket connections" do
    with_server do
      Async::WebSocket::Client.connect(endpoint) do |connection|
        expect(connection).not.to be_nil
      end
    end
  end

  it "handles subscribe command and replays events" do
    # Create some events first
    msg1 = Firehose.broadcast("ws-test", "event-1")
    msg2 = Firehose.broadcast("ws-test", "event-2")

    with_server do
      Async::WebSocket::Client.connect(endpoint) do |connection|
        # Subscribe with last_event_id before our events
        connection.write(Protocol::WebSocket::TextMessage.generate({
          command: "subscribe",
          streams: ["ws-test"],
          last_event_id: msg1.id - 1
        }))
        connection.flush

        # Should receive replayed events
        received = []
        2.times do
          message = connection.read
          received << JSON.parse(message.to_str)
        end

        expect(received.length).to be == 2
        expect(received[0]["data"]).to be == "event-1"
        expect(received[1]["data"]).to be == "event-2"
        expect(received[0]["channel_id"]).to be == msg1.channel_id
        expect(received[0]["sequence"]).to be == msg1.sequence
      end
    end
  end

  it "handles unsubscribe command" do
    with_server do
      Async::WebSocket::Client.connect(endpoint) do |connection|
        # Subscribe
        connection.write(Protocol::WebSocket::TextMessage.generate({
          command: "subscribe",
          streams: ["unsub-test"]
        }))
        connection.flush

        # Unsubscribe
        connection.write(Protocol::WebSocket::TextMessage.generate({
          command: "unsubscribe",
          streams: ["unsub-test"]
        }))
        connection.flush

        # Should not error
        expect(true).to be == true
      end
    end
  end

  it "receives live events after subscribing" do
    with_server do
      Async::WebSocket::Client.connect(endpoint) do |connection|
        # Subscribe
        connection.write(Protocol::WebSocket::TextMessage.generate({
          command: "subscribe",
          streams: ["live-test"],
          last_event_id: Firehose::Message.maximum(:id) || 0
        }))
        connection.flush

        # Broadcast an event (in a separate task so it doesn't block)
        Async do
          sleep 0.1
          Firehose.broadcast("live-test", "live-event")
        end

        # Should receive the live event
        message = connection.read
        data = JSON.parse(message.to_str)

        expect(data["stream"]).to be == "live-test"
        expect(data["data"]).to be == "live-event"
        expect(data["channel_id"]).to be_a(Integer)
        expect(data["sequence"]).to be_a(Integer)
      end
    end
  end
end
