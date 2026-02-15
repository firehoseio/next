require_relative "test_helper"
require "rails/command"
require "commands/firehose_command"

describe Firehose::Command::FirehoseCommand do
  # Stub boot_application! globally for tests since the app is already booted
  before do
    Firehose::Command::FirehoseCommand.define_method(:boot_application!) { }
  end

  def capture_command(*args)
    output = StringIO.new
    old_stdout = $stdout
    $stdout = output
    Firehose::Command::FirehoseCommand.start(args.map(&:to_s))
    output.string
  ensure
    $stdout = old_stdout
  end

  with "status" do
    it "outputs channel and message counts" do
      Firehose.channel("status-test-#{SecureRandom.hex(4)}").publish("hello")

      output = capture_command("status")

      expect(output).to be =~ /channels: \d+/
      expect(output).to be =~ /total: \d+/
      expect(output).to be =~ /last_minute:/
      expect(output).to be =~ /last_hour:/
      expect(output).to be =~ /last_day:/
    end
  end

  with "channels" do
    it "lists channels with sequence and message counts" do
      name = "cmd-ch-#{SecureRandom.hex(4)}"
      Firehose.channel(name).publish("data")

      output = capture_command("channels")

      expect(output).to be(:include?, "NAME")
      expect(output).to be(:include?, "SEQUENCE")
      expect(output).to be(:include?, name)
    end

    it "shows empty message when no channels exist" do
      Firehose::Models::Message.delete_all
      Firehose::Models::Channel.delete_all

      output = capture_command("channels")

      expect(output.strip).to be == "No channels."
    end
  end

  with "messages" do
    it "lists recent messages" do
      name = "cmd-msg-#{SecureRandom.hex(4)}"
      Firehose.channel(name).publish("test-data")

      output = capture_command("messages")

      expect(output).to be(:include?, "test-data")
      expect(output).to be(:include?, name)
    end

    it "shows empty message when no messages exist" do
      Firehose::Models::Message.delete_all
      Firehose::Models::Channel.delete_all

      output = capture_command("messages")

      expect(output.strip).to be == "No messages."
    end

    it "filters by channel" do
      target = "filter-target-#{SecureRandom.hex(4)}"
      other = "filter-other-#{SecureRandom.hex(4)}"
      Firehose.channel(target).publish("yes")
      Firehose.channel(other).publish("no")

      output = capture_command("messages", "--channel", target)

      expect(output).to be(:include?, target)
      expect(output).not.to be(:include?, other)
    end

    it "respects the limit option" do
      name = "limit-msg-#{SecureRandom.hex(4)}"
      5.times { |i| Firehose.channel(name).publish("msg-#{i}") }

      output = capture_command("messages", "--channel", name, "--limit", "2")

      lines = output.lines.select { |l| l.include?(name) }
      expect(lines.size).to be == 2
    end
  end
end
