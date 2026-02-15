return if defined?(FirehoseTestApp)

ENV["RAILS_ENV"] = "test"
ENV["DATABASE_URL"] ||= "postgres://localhost/firehose_test"

require "bundler/setup"
require "rails"
require "active_record/railtie"
require "active_job/railtie"
require "action_controller/railtie"
require "firehose"

class FirehoseTestApp < Rails::Application
  config.root = File.expand_path("..", __dir__)
  config.eager_load = false
  config.active_job.queue_adapter = :inline
  config.logger = Logger.new(File::NULL)
end

Rails.application.initialize!

ActiveRecord::Migration.verbose = false
ActiveRecord::MigrationContext.new([Firehose::Engine.root.join("db/migrate").to_s]).migrate
