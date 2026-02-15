module Firehose
  class Engine < ::Rails::Engine
    initializer "firehose.migrations" do |app|
      app.config.paths["db/migrate"].concat(config.paths["db/migrate"].expanded)
    end

    initializer "firehose.server" do |app|
      Firehose.server = Firehose::Server.new

      rb_config = app.root.join("config/firehose.rb")
      yml_config = app.root.join("config/firehose.yml")

      if rb_config.exist?
        load rb_config
      elsif yml_config.exist?
        Firehose.server.configure_from_yaml(yml_config)
      end

      Firehose.server.start
    end

    at_exit do
      Firehose.server.shutdown rescue nil
    end
  end
end
