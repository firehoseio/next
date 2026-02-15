module Firehose
  module Command
    class MessagesCommand < Rails::Command::Base
      namespace "firehose:messages"

      class_option :tail, type: :boolean, default: false, aliases: "-f",
        desc: "Follow new messages as they arrive"
      class_option :channel, type: :string, aliases: "-c",
        desc: "Filter to a specific channel"
      class_option :limit, type: :numeric, default: 20, aliases: "-n",
        desc: "Number of recent messages to show"

      desc "messages", "List recent messages (use --tail to follow live)"

      def perform
        require_application_and_environment!

        scope = Models::Message.includes(:channel).order(id: :desc)
        scope = scope.joins(:channel).where(firehose_channels: { name: options[:channel] }) if options[:channel]

        # Show recent messages
        messages = scope.limit(options[:limit]).to_a.reverse

        if messages.any?
          messages.each { |msg| print_message(msg) }
        else
          puts "No messages."
        end

        return unless options[:tail]

        puts
        puts "--- following new messages (Ctrl+C to exit) ---"
        puts

        trap("INT") { puts; exit }

        last_id = Models::Message.maximum(:id) || 0

        loop do
          new_scope = Models::Message.where("id > ?", last_id).includes(:channel).order(:id)
          new_scope = new_scope.joins(:channel).where(firehose_channels: { name: options[:channel] }) if options[:channel]

          new_scope.each do |msg|
            print_message(msg)
            last_id = msg.id
          end

          sleep 0.5
        end
      end

      private

      def print_message(msg)
        time = msg.created_at.strftime("%H:%M:%S.%L")
        data = msg.data.truncate(80)
        puts "[#{time}] ##{msg.id} #{msg.channel.name} seq:#{msg.sequence} #{data}"
      end
    end
  end
end
