module Firehose
  module Command
    class FirehoseCommand < Rails::Command::Base
      desc "firehose", "Show live Firehose server stats (refreshes every second)"

      def perform
        require_application_and_environment!

        trap("INT") { puts; exit }

        loop do
          print "\e[2J\e[H" # clear screen, cursor to top

          channels = Models::Channel.order(sequence: :desc)
          total_messages = Models::Message.count
          last_min = Models::Message.where("created_at > ?", 1.minute.ago).count
          last_hr = Models::Message.where("created_at > ?", 1.hour.ago).count
          last_day = Models::Message.where("created_at > ?", 1.day.ago).count

          puts "Firehose Status (refreshing every 1s, Ctrl+C to exit)"
          puts "=" * 56
          puts
          puts "  Server"
          puts "    PID:               #{Process.pid}"
          puts "    Cleanup threshold: #{Firehose.server.cleanup_threshold}"
          puts "    Notify max bytes:  #{Firehose.server.notify_max_bytes}"
          puts
          puts "  Messages"
          puts "    Total:    #{total_messages}"
          puts "    Last min: #{last_min}"
          puts "    Last hr:  #{last_hr}"
          puts "    Last day: #{last_day}"
          puts
          puts "  Channels (#{channels.count})"

          if channels.any?
            name_width = [channels.map { |c| c.name.length }.max, 30].min
            channels.each do |ch|
              name = ch.name.truncate(name_width)
              puts "    %-#{name_width}s  seq: %-6d  msgs: %d" % [name, ch.sequence, ch.messages_count]
            end
          else
            puts "    (none)"
          end

          puts

          sleep 1
        end
      end
    end
  end
end
