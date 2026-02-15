module Firehose
  module Command
    class ChannelsCommand < Rails::Command::Base
      namespace "firehose:channels"

      desc "channels", "List all Firehose channels"

      def perform
        require_application_and_environment!

        channels = Models::Channel.order(sequence: :desc)

        if channels.empty?
          puts "No channels."
          return
        end

        name_width = [channels.map { |c| c.name.length }.max, 40].min

        puts "%-#{name_width}s  %8s  %8s  %s" % ["NAME", "SEQUENCE", "MESSAGES", "LATEST MESSAGE"]
        puts "-" * (name_width + 50)

        channels.each do |ch|
          latest = ch.messages.order(id: :desc).first
          latest_at = latest ? latest.created_at.strftime("%Y-%m-%d %H:%M:%S") : "-"
          name = ch.name.truncate(name_width)
          puts "%-#{name_width}s  %8d  %8d  %s" % [name, ch.sequence, ch.messages_count, latest_at]
        end

        puts
        puts "#{channels.count} channel(s)"
      end
    end
  end
end
