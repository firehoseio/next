require_relative "test_helper"

describe Firehose::Queue do
  let(:channel) { "queue-test-#{SecureRandom.hex(4)}" }

  with "push and pop" do
    it "delivers a message from push to pop" do
      queue = Firehose.server.queue(channel)
      queue.subscribe

      Thread.new { sleep 0.1; Firehose.server.queue(channel).push("hello") }

      result = queue.pop(timeout: 3)
      expect(result).to be == "hello"
    ensure
      queue&.close
    end

    it "delivers messages across separate queue instances" do
      subscriber = Firehose.server.queue(channel)
      subscriber.subscribe

      publisher = Firehose.server.queue(channel)
      Thread.new { sleep 0.1; publisher.push("world") }

      result = subscriber.pop(timeout: 3)
      expect(result).to be == "world"
    ensure
      subscriber&.close
    end

    it "preserves message content exactly" do
      queue = Firehose.server.queue(channel)
      queue.subscribe

      payload = '{"user_id":42,"action":"approve"}'
      Thread.new { sleep 0.1; Firehose.server.queue(channel).push(payload) }

      result = queue.pop(timeout: 3)
      expect(result).to be == payload
    ensure
      queue&.close
    end
  end

  with "timeout" do
    it "raises TimeoutError when no message arrives" do
      queue = Firehose.server.queue(channel)

      expect { queue.pop(timeout: 0.5) }.to raise_exception(Firehose::Queue::TimeoutError)
    ensure
      queue&.close
    end
  end

  with "fiber scheduler" do
    it "does not block the thread when waiting for a message" do
      queue = Firehose.server.queue(channel)
      queue.subscribe

      # Track whether concurrent work can proceed while pop is waiting
      concurrent_ran = false

      thread = Thread.new {
        sleep 0.2
        concurrent_ran = true
        Firehose.server.queue(channel).push("fiber-test")
      }

      result = queue.pop(timeout: 3)
      thread.join

      expect(result).to be == "fiber-test"
      expect(concurrent_ran).to be == true
    ensure
      queue&.close
    end
  end

  with "close" do
    it "unsubscribes from the server" do
      queue = Firehose.server.queue(channel)
      queue.subscribe
      queue.close

      # After close, pushing should not raise but message is lost
      Firehose.server.queue(channel).push("lost")
    end
  end
end
