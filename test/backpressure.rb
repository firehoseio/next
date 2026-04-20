require_relative "test_helper"

describe Firehose::Server do
  with "max_command_queue_depth backpressure" do
    let(:server) { Firehose::Server.new }

    it "drops NOTIFY commands when the queue is at cap" do
      server.max_command_queue_depth = 10

      # Prefill the queue without actually starting the consumer.
      # enqueue pushes onto @commands directly.
      commands = server.instance_variable_get(:@commands)
      10.times { commands.push([:notify, "x", "y"]) }

      # The 11th notify should be dropped.
      server.send(:enqueue, [:notify, "x", "z"])
      expect(commands.size).to be == 10

      snap = server.metrics_snapshot
      expect(snap[:commands_dropped]).to be == 1
    end

    it "never drops :listen even at cap" do
      server.max_command_queue_depth = 5

      commands = server.instance_variable_get(:@commands)
      5.times { commands.push([:notify, "x", "y"]) }

      server.send(:enqueue, [:listen, "channel-xyz"])
      expect(commands.size).to be == 6  # listen admitted through
    end

    it "never drops :unlisten even at cap" do
      server.max_command_queue_depth = 5

      commands = server.instance_variable_get(:@commands)
      5.times { commands.push([:notify, "x", "y"]) }

      server.send(:enqueue, [:unlisten, "channel-xyz"])
      expect(commands.size).to be == 6
    end

    it "never drops :shutdown even at cap" do
      server.max_command_queue_depth = 5

      commands = server.instance_variable_get(:@commands)
      5.times { commands.push([:notify, "x", "y"]) }

      server.send(:enqueue, [:shutdown])
      expect(commands.size).to be == 6
    end

    it "is disabled by default (unbounded queue growth)" do
      expect(server.max_command_queue_depth).to be == nil

      commands = server.instance_variable_get(:@commands)
      1000.times { server.send(:enqueue, [:notify, "x", "y"]) }
      expect(commands.size).to be == 1000
    end
  end
end
