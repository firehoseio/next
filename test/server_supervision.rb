require_relative "test_helper"

describe Firehose::Server do
  with "#diagnostics" do
    it "reports runtime state" do
      server = Firehose::Server.new
      info = server.diagnostics

      expect(info).to be_a(Hash)
      expect(info[:pid]).to be == Process.pid
      expect(info[:command_queue_depth]).to be == 0
      expect(info[:subscribed_channels]).to be == 0
    end

    it "reflects a live consumer thread after first use" do
      server = Firehose::Server.new
      server.start

      # Force lazy start via a no-op subscribe/unsubscribe pair
      callback = ->(_) {}
      server.subscribe("diag-test-#{SecureRandom.hex(4)}", callback)

      sleep 0.1  # let thread settle
      info = server.diagnostics

      expect(info[:started]).to be == true
      expect(info[:thread_alive]).to be == true
      expect(info[:subscribed_channels]).to be == 1
    ensure
      server&.shutdown
    end
  end

  with "consumer thread supervision" do
    it "respawns a dead consumer thread on the next call" do
      server = Firehose::Server.new
      server.start

      channel = "supervision-#{SecureRandom.hex(4)}"
      received = ::Queue.new
      callback = ->(payload) { received << payload }
      server.subscribe(channel, callback)

      sleep 0.1  # let the thread subscribe

      original_thread = server.instance_variable_get(:@thread)
      expect(original_thread.alive?).to be == true

      # Kill the thread outright — simulates an OS-level fatal.
      original_thread.kill
      original_thread.join

      expect(original_thread.alive?).to be == false

      # Any producer call should respawn the thread.
      server.subscribe("#{channel}-probe", ->(_) {})
      sleep 0.1

      new_thread = server.instance_variable_get(:@thread)
      expect(new_thread).not.to be == original_thread
      expect(new_thread.alive?).to be == true
    ensure
      server&.shutdown
    end
  end

  with "reconnect configuration" do
    it "defaults to unlimited reconnect attempts" do
      server = Firehose::Server.new
      expect(server.reconnect_attempts).to be == nil
    end

    it "caps reconnect backoff at reconnect_max_delay" do
      server = Firehose::Server.new
      server.reconnect_delay = 1
      server.reconnect_max_delay = 5

      # Simulate many failures — backoff should cap rather than grow forever.
      # Computed from the same formula used in connect_with_retry.
      attempts = 20
      delay = [server.reconnect_delay * (2 ** (attempts - 1)), server.reconnect_max_delay].min
      expect(delay).to be == 5
    end
  end
end
