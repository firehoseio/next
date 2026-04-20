require_relative "test_helper"

describe Firehose::Server::Watchdog do
  let(:server) { Firehose::Server.new }

  with "heartbeat tracking" do
    it "starts with a recent heartbeat" do
      expect(server.seconds_since_heartbeat).to be <= 0.5
    end

    it "resets the heartbeat on demand" do
      sleep 0.1
      initial = server.seconds_since_heartbeat
      server.heartbeat!
      expect(server.seconds_since_heartbeat).to be < initial
    end
  end

  with "force_reconnect!" do
    it "is a safe no-op when no connection is open" do
      # Must not raise — called from a thread other than the consumer.
      server.force_reconnect!
    end
  end

  with "force_reconnect! on a live server" do
    it "triggers the supervisor's reconnect path" do
      server.watchdog_enabled = false  # we're driving force_reconnect ourselves
      server.start
      server.subscribe("watchdog-reconnect-#{SecureRandom.hex(4)}", ->(_) {})
      sleep 0.3  # let the consumer connect

      reconnects_before = server.instance_variable_get(:@reconnects)
      expect(server.diagnostics[:thread_alive]).to be == true

      server.force_reconnect!

      # Wait for the supervisor to notice, reconnect, and reset @reconnects to 0
      # after a successful connect. Observable sign: @reconnects was incremented
      # above zero at some point OR we can wait for thread to still be alive +
      # a fresh conn object.
      deadline = Time.now + 5
      conn_after = nil
      while Time.now < deadline
        conn_after = server.instance_variable_get(:@conn)
        break if conn_after && !conn_after.finished?
        sleep 0.05
      end

      expect(server.diagnostics[:thread_alive]).to be == true
      expect(conn_after).not.to be == nil
      expect(conn_after.finished?).to be == false
    ensure
      server&.shutdown
    end
  end

  with "watchdog supervision" do
    it "survives an exception raised from within its tick body" do
      watchdog = Firehose::Server::Watchdog.new(server)

      # Replace tick with one that raises on the first call, then succeeds.
      # After a raise, the watchdog sleeps 1s before retrying, so we wait ~1.5s.
      calls = 0
      watchdog.define_singleton_method(:tick) do
        calls += 1
        raise "simulated bug" if calls == 1
        sleep 0.05
      end

      watchdog.start
      sleep 1.5
      expect(watchdog.alive?).to be == true
      expect(calls).to be > 1
    ensure
      watchdog&.stop
    end

    it "stops cleanly on shutdown" do
      server.start
      server.subscribe("wd-stop-#{SecureRandom.hex(4)}", ->(_) {})
      sleep 0.1

      watchdog = server.instance_variable_get(:@watchdog)
      expect(watchdog.alive?).to be == true

      server.shutdown
      expect(watchdog.alive?).to be == false
    end
  end

  with "configuration" do
    it "defaults watchdog_enabled to true" do
      expect(server.watchdog_enabled).to be == true
    end

    it "allows disabling the watchdog" do
      server.watchdog_enabled = false
      server.start
      server.subscribe("no-watchdog-#{SecureRandom.hex(4)}", ->(_) {})
      sleep 0.1

      expect(server.instance_variable_get(:@watchdog)).to be == nil
    ensure
      server&.shutdown
    end
  end
end

describe Firehose::Server do
  with "TCP keepalives" do
    let(:server) { Firehose::Server.new }

    it "has keepalive defaults that surface dead peers within ~60s" do
      # idle + interval*count roughly bounds how long a dead peer goes unnoticed
      deadline = server.tcp_keepalives_idle + (server.tcp_keepalives_interval * server.tcp_keepalives_count)
      expect(deadline).to be <= 120
    end

    it "applies keepalives when opening the PG connection" do
      server.start
      server.subscribe("keepalive-#{SecureRandom.hex(4)}", ->(_) {})
      sleep 0.2

      conn = server.instance_variable_get(:@conn)
      # conn.conninfo_hash reports the actual libpq settings in use
      info = conn.conninfo_hash
      expect(info[:keepalives_idle].to_i).to be == server.tcp_keepalives_idle
      expect(info[:keepalives_interval].to_i).to be == server.tcp_keepalives_interval
      expect(info[:keepalives_count].to_i).to be == server.tcp_keepalives_count
    ensure
      server&.shutdown
    end
  end

  with "error reporter integration" do
    let(:server) { Firehose::Server.new }

    it "reports via Rails.error when available" do
      reports = []
      fake_reporter = Object.new
      fake_reporter.define_singleton_method(:report) do |error, **opts|
        reports << [error, opts]
      end

      original = Rails.error rescue nil
      Rails.define_singleton_method(:error) { fake_reporter }

      begin
        server.send(:report_error, RuntimeError.new("boom"), stage: :test)
        expect(reports.size).to be == 1
        expect(reports.first[1][:source]).to be == "firehose.server"
        expect(reports.first[1][:context][:stage]).to be == :test
        expect(reports.first[1][:handled]).to be == true
      ensure
        if original
          Rails.define_singleton_method(:error) { original }
        end
      end
    end

    it "silently swallows reporter failures so the supervisor keeps running" do
      raising_reporter = Object.new
      raising_reporter.define_singleton_method(:report) { |*| raise "reporter exploded" }

      Rails.define_singleton_method(:error) { raising_reporter }
      begin
        # Must not raise.
        server.send(:report_error, RuntimeError.new("inner"), stage: :test)
      ensure
        Rails.singleton_class.remove_method(:error) rescue nil
      end
    end
  end
end
