module Firehose
  class Engine < ::Rails::Engine
    initializer "firehose.migrations" do |app|
      app.config.paths["db/migrate"].concat(config.paths["db/migrate"].expanded)
    end
  end
end
