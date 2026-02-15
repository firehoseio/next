module Firehose
  module Command
    class InstallCommand < Rails::Command::Base
      namespace "firehose:install"

      desc "install", "Install Firehose (creates controller, routes, JS import, runs migrations)"

      def perform
        require_application_and_environment!
        Rails::Generators.invoke("firehose:install", [], behavior: :invoke)
      end
    end
  end
end
