require_relative "test_helper"
require "async/websocket"

describe "Replay gap detection" do
  let(:stream) { "replay-gap-#{SecureRandom.hex(4)}" }

  with "WebSocket handler" do
    # Smallest thing that can stand in for the controller.
    let(:controller) do
      Class.new do
        def authorize_streams(s) = s
        def build_event(e) = e
      end.new
    end

    it "emits replay_gap when the client's last_event_id is older than retained messages" do
      # Create a channel with a message at a known id.
      channel = Firehose::Models::Channel.create!(name: stream)
      channel.messages.create!(sequence: 1, data: "msg-a")
      second = channel.messages.create!(sequence: 2, data: "msg-b")

      # Capture events the handler would send.
      sent = []
      fake_conn = Object.new
      fake_conn.define_singleton_method(:write) { |msg| sent << msg }
      fake_conn.define_singleton_method(:flush) { nil }
      fake_conn.define_singleton_method(:define_singleton_method) { |*, &_| }
      fake_conn.define_singleton_method(:send_ping) { nil }

      handler = Firehose::WebSocket::WebSocketHandler.new(fake_conn, controller: controller)

      # Ask to replay from an id older than the oldest retained message.
      handler.send(:replay_events, [stream], 0)

      frames = sent.map(&:to_str).map { |s| JSON.parse(s, symbolize_names: true) }
      gap = frames.find { |f| f[:error] == "replay_gap" }

      expect(gap).not.to be == nil
      expect(gap[:stream]).to be == stream
      expect(gap[:last_event_id]).to be == 0
      expect(gap[:oldest_retained_id]).to be == channel.messages.minimum(:id)
      expect(gap[:current_id]).to be == second.id
    end

    it "emits normal events when last_event_id is within retention" do
      channel = Firehose::Models::Channel.create!(name: stream)
      first = channel.messages.create!(sequence: 1, data: "msg-a")
      second = channel.messages.create!(sequence: 2, data: "msg-b")

      sent = []
      fake_conn = Object.new
      fake_conn.define_singleton_method(:write) { |msg| sent << msg }
      fake_conn.define_singleton_method(:flush) { nil }
      fake_conn.define_singleton_method(:define_singleton_method) { |*, &_| }
      fake_conn.define_singleton_method(:send_ping) { nil }

      handler = Firehose::WebSocket::WebSocketHandler.new(fake_conn, controller: controller)

      # Client asks to replay since `first.id`; retained window covers it.
      handler.send(:replay_events, [stream], first.id)

      frames = sent.map(&:to_str).map { |s| JSON.parse(s, symbolize_names: true) }
      gap = frames.find { |f| f[:error] == "replay_gap" }
      expect(gap).to be == nil

      delivered_ids = frames.map { |f| f[:id] }.compact
      expect(delivered_ids).to be == [second.id]
    end
  end
end
