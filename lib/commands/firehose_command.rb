module Firehose
  module Command
    class FirehoseCommand < Rails::Command::Base
      namespace "firehose"

      desc "status", "Show Firehose stats (--watch to refresh)"
      option :watch, type: :numeric, default: nil, aliases: "-w", lazy_default: 1,
        desc: "Refresh every N seconds (default: 1)"
      def status
        boot_application!

        if options[:watch]
          trap("INT") { puts; exit }
          loop do
            print "\e[2J\e[H"
            print_stats
            sleep options[:watch]
          end
        else
          print_stats
        end
      end

      default_command :status

      desc "channels", "List Firehose channels"
      option :limit, type: :numeric, default: 50, aliases: "-n",
        desc: "Number of channels to show"
      def channels
        boot_application!

        total = Models::Channel.count
        channels = Models::Channel.order(sequence: :desc).limit(options[:limit])

        if channels.empty?
          puts "No channels."
          return
        end

        name_width = [channels.map { |c| c.name.length }.max, 40].min

        puts "%-#{name_width}s  %8s  %8s  %s" % ["NAME", "SEQUENCE", "MESSAGES", "LATEST MESSAGE"]
        puts "-" * (name_width + 50)

        channels.each do |ch|
          latest = ch.messages.order(id: :desc).limit(1).pick(:created_at)
          latest_at = latest ? latest.strftime("%Y-%m-%d %H:%M:%S") : "-"
          puts "%-#{name_width}s  %8d  %8d  %s" % [ch.name.truncate(name_width), ch.sequence, ch.messages_count, latest_at]
        end

        puts
        puts "#{channels.size} of #{total} channel(s)"
      end

      desc "messages", "List recent messages (use --tail to follow live)"
      option :tail, type: :boolean, default: false, aliases: "-f",
        desc: "Follow new messages as they arrive"
      option :channel, type: :string, aliases: "-c",
        desc: "Filter to a specific channel"
      option :limit, type: :numeric, default: 20, aliases: "-n",
        desc: "Number of recent messages to show"
      def messages
        boot_application!

        scope = Models::Message.includes(:channel).order(id: :desc)
        scope = scope.joins(:channel).where(firehose_channels: { name: options[:channel] }) if options[:channel]

        messages = scope.limit(options[:limit]).to_a.reverse

        if messages.any?
          messages.each { |msg| print_message(msg) }
        else
          puts "No messages."
        end

        return unless options[:tail]

        trap("INT") { puts; exit }

        last_id = Models::Message.maximum(:id) || 0

        loop do
          new_scope = Models::Message.where("id > ?", last_id).includes(:channel).order(:id).limit(100)
          new_scope = new_scope.joins(:channel).where(firehose_channels: { name: options[:channel] }) if options[:channel]

          new_scope.each do |msg|
            print_message(msg)
            last_id = msg.id
          end

          sleep 0.5
        end
      end

      desc "install", "Install Firehose (creates controller, routes, JS import, runs migrations)"
      def install
        boot_application!
        Rails::Generators.invoke("firehose:install", [], behavior: :invoke)
      end

      private

      def print_stats
        puts "channels: #{Models::Channel.count}"
        puts "messages:"
        puts "  total: #{Models::Message.count}"
        puts "  last_minute: #{Models::Message.where("created_at > ?", 1.minute.ago).count}"
        puts "  last_hour: #{Models::Message.where("created_at > ?", 1.hour.ago).count}"
        puts "  last_day: #{Models::Message.where("created_at > ?", 1.day.ago).count}"
      end

      def print_message(msg)
        time = msg.created_at.strftime("%H:%M:%S.%L")
        data = msg.data.truncate(80)
        puts "[#{time}] ##{msg.id} #{msg.channel.name} seq:#{msg.sequence} #{data}"
      end
    end
  end
end
