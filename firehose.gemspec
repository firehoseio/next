Gem::Specification.new do |spec|
  spec.name = "firehose"
  spec.version = "2.0.0"
  spec.authors = ["Brad Gessler"]
  spec.email = ["brad@bradgessler.com"]

  spec.summary = "WebSocket and SSE streaming with database-backed replay"
  spec.description = "Real-time streaming for Rails with PostgreSQL persistence and replay support. Supports both WebSocket and Server-Sent Events transports with automatic reconnection and event replay."
  spec.homepage = "https://github.com/opengraphplus/firehose"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata = {
    "homepage_uri" => spec.homepage,
    "source_code_uri" => spec.homepage,
    "changelog_uri" => "#{spec.homepage}/blob/main/CHANGELOG.md"
  }

  spec.files = Dir.chdir(__dir__) do
    Dir["{app,config,lib,db}/**/*", "README.md", "LICENSE", "CHANGELOG.md"].reject { |f| File.directory?(f) }
  end

  spec.bindir = "bin"
  spec.require_paths = ["lib"]

  spec.add_dependency "rails", ">= 7.0"
  spec.add_dependency "pg"
  spec.add_dependency "async-websocket"
end
