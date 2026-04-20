require_relative "test_helper"

# Integration tests that inject failures into a live Firehose::Server and
# assert the reliability primitives recover. Each scenario here is mapped
# directly to a production failure mode — regressions in any of them would
# reintroduce real outages.

describe "Firehose::Server chaos" do
  with "consumer thread killed mid-operation" do
    let(:server) { Firehose::Server.new }

    it "respawns and resumes delivery without losing the subscription" do
      stream = "chaos-kill-#{SecureRandom.hex(4)}"
      server.start
      received = ::Queue.new
      server.subscribe(server.channel_name(stream), ->(payload) { received << payload })
      sleep 0.2  # let LISTEN complete

      server.broadcast(stream, "before-kill")
      first = received.pop(timeout: 3)
      expect(JSON.parse(first)["data"]).to be == "before-kill"

      # Violently kill the consumer thread. Every guarantee the
      # supervisor + ensure_started! pair claim to provide hinges on
      # recovery from exactly this kind of event.
      victim = server.instance_variable_get(:@thread)
      victim.kill
      victim.join

      # The next producer call must respawn the consumer AND re-LISTEN.
      server.broadcast(stream, "after-kill")
      second = received.pop(timeout: 5)
      expect(JSON.parse(second)["data"]).to be == "after-kill"

      respawn = server.instance_variable_get(:@thread)
      expect(respawn).not.to be == victim
      expect(respawn.alive?).to be == true
    ensure
      server&.shutdown
    end
  end

  with "PG socket severed mid-serve" do
    let(:server) { Firehose::Server.new }

    it "supervisor reconnects and continues delivering" do
      stream = "chaos-socket-#{SecureRandom.hex(4)}"
      server.start
      received = ::Queue.new
      server.subscribe(server.channel_name(stream), ->(payload) { received << payload })
      sleep 0.3

      server.broadcast(stream, "pre-sever")
      expect(JSON.parse(received.pop(timeout: 3))["data"]).to be == "pre-sever"

      # Force the supervisor to reconnect by closing the socket, exactly
      # the same mechanism the watchdog uses.
      server.force_reconnect!

      # Poll for the supervisor to swap in a fresh connection.
      deadline = Time.now + 5
      conn_after = nil
      while Time.now < deadline
        conn_after = server.instance_variable_get(:@conn)
        break if conn_after && !conn_after.finished?
        sleep 0.05
      end
      expect(conn_after).not.to be == nil
      expect(conn_after.finished?).to be == false

      server.broadcast(stream, "post-sever")
      expect(JSON.parse(received.pop(timeout: 3))["data"]).to be == "post-sever"
    ensure
      server&.shutdown
    end
  end

  with "watchdog-driven force reconnect" do
    let(:server) { Firehose::Server.new }

    it "trips the watchdog when the heartbeat goes stale and recovers" do
      server.watchdog_deadline = 1
      server.watchdog_interval = 0.2
      server.start
      stream = "chaos-watchdog-#{SecureRandom.hex(4)}"
      received = ::Queue.new
      server.subscribe(server.channel_name(stream), ->(payload) { received << payload })
      sleep 0.3

      kicks_before = server.metrics_snapshot[:watchdog_kicks]

      # Fake a stale heartbeat by rewinding @heartbeat_at directly.
      # (The consumer would update it again on the next iteration, but the
      # watchdog check fires on its own interval; with deadline=1 the next
      # tick should trip.)
      server.instance_variable_set(:@heartbeat_at,
        Process.clock_gettime(Process::CLOCK_MONOTONIC) - 10)

      # Wait long enough for the watchdog to notice + kick + the
      # supervisor to reconnect.
      sleep 2.0

      kicks_after = server.metrics_snapshot[:watchdog_kicks]
      expect(kicks_after).to be > kicks_before

      # Verify delivery still works after the kick.
      server.broadcast(stream, "post-watchdog-kick")
      expect(JSON.parse(received.pop(timeout: 3))["data"]).to be == "post-watchdog-kick"
    ensure
      server&.shutdown
    end
  end

  with "malformed command in the queue" do
    let(:server) { Firehose::Server.new }

    it "supervisor survives a command tuple that doesn't match any pattern" do
      server.start
      # Subscribe so the consumer thread has LISTEN registered and
      # can't exit through the :shutdown path.
      server.subscribe("chaos-malformed-#{SecureRandom.hex(4)}", ->(_) {})
      sleep 0.2

      thread_before = server.instance_variable_get(:@thread)
      expect(thread_before.alive?).to be == true

      # Inject a command that won't match any `in` clause.
      # process_commands will raise NoMatchingPatternError; the
      # supervisor catches, logs, sleeps 1s, restarts the serve loop.
      server.instance_variable_get(:@commands).push([:unknown_op, "junk"])
      server.instance_variable_get(:@wakeup_write).write_nonblock("x")

      sleep 2.0  # outer supervisor's sleep + reconnect

      # Same thread, still alive — we want the supervisor to absorb, not
      # for ensure_started! to respawn (that would be a slower path).
      expect(thread_before.alive?).to be == true
    ensure
      server&.shutdown
    end
  end

  with "subscriber callback that raises" do
    let(:server) { Firehose::Server.new }

    it "doesn't kill the consumer thread or other subscribers" do
      stream = "chaos-callback-#{SecureRandom.hex(4)}"
      server.start

      good = ::Queue.new
      server.subscribe(server.channel_name(stream), ->(_) { raise "from callback" })
      server.subscribe(server.channel_name(stream), ->(payload) { good << payload })
      sleep 0.2

      thread_before = server.instance_variable_get(:@thread)
      server.broadcast(stream, "with-raising-callback")

      # The good subscriber still receives even if the raising one blew up.
      delivered = good.pop(timeout: 3)
      expect(JSON.parse(delivered)["data"]).to be == "with-raising-callback"
      expect(thread_before.alive?).to be == true
    ensure
      server&.shutdown
    end
  end

  with "shutdown during active subscription" do
    let(:server) { Firehose::Server.new }

    it "tears down every supervised thread cleanly" do
      server.start
      server.subscribe("chaos-shutdown-#{SecureRandom.hex(4)}", ->(_) {})
      sleep 0.2

      watchdog = server.instance_variable_get(:@watchdog)
      notify_pool = server.instance_variable_get(:@notify_pool)
      consumer = server.instance_variable_get(:@thread)

      expect(consumer.alive?).to be == true
      expect(watchdog.alive?).to be == true
      expect(notify_pool.running?).to be == true

      server.shutdown

      expect(consumer.alive?).to be == false
      expect(watchdog.alive?).to be == false
      expect(notify_pool.running?).to be == false
    end
  end

  with "post-shutdown producer calls" do
    let(:server) { Firehose::Server.new }

    it "does not respawn a zombie consumer thread" do
      server.start
      server.subscribe("chaos-post-#{SecureRandom.hex(4)}", ->(_) {})
      sleep 0.1
      server.shutdown

      # A late producer call must not revive the thread. Previously
      # ensure_started! would see @started=true & !alive? and try to
      # respawn — but the wakeup pipe is already closed, producing a
      # zombie that never drains.
      server.subscribe("chaos-late-#{SecureRandom.hex(4)}", ->(_) {})

      expect(server.instance_variable_get(:@thread)&.alive?).to be == false
    end

    it "doesn't raise when enqueue is called after shutdown" do
      server.start
      server.subscribe("chaos-enqueue-#{SecureRandom.hex(4)}", ->(_) {})
      sleep 0.1
      server.shutdown

      # The wakeup pipe is closed; write_nonblock would raise IOError.
      # enqueue must swallow that rather than crash the caller.
      server.send(:enqueue, [:notify, "abc", "late"])
      server.send(:enqueue, [:ping])
      # no exception reaches here
    end
  end
end
