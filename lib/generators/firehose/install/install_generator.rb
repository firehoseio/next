module Firehose
  module Generators
    class InstallGenerator < Rails::Generators::Base
      source_root File.expand_path("templates", __dir__)

      def create_controller
        template "firehose_controller.rb", "app/controllers/firehose_controller.rb"
      end

      def add_routes
        route <<~RUBY
          match "firehose", to: "firehose#websocket", via: [:get, :connect]
          get "firehose/sse", to: "firehose#sse"
        RUBY
      end

      def add_javascript_import
        js_file = "app/javascript/application.js"
        return unless File.exist?(js_file)

        import_line = 'import "firehose"'
        return if File.read(js_file).include?(import_line)

        append_to_file js_file, "\n#{import_line}\n"
      end

      def run_migrations
        rails_command "db:migrate"
      end

      def print_next_steps
        say ""
        say "Firehose installed!", :green
        say ""
        say "  Broadcast:   Firehose.broadcast(\"my-stream\", \"refresh\")"
        say "  Subscribe:   <firehose-stream-source streams=\"my-stream\"></firehose-stream-source>"
        say ""
        say "  Edit app/controllers/firehose_controller.rb to add authentication."
        say ""
      end
    end
  end
end
