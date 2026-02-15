require "bundler/gem_tasks"

task default: :test

desc "Run tests (requires Rails app context)"
task :test do
  # Tests require Rails environment, run from parent app
  Dir.chdir("../..") do
    exec "RAILS_ENV=test bundle exec sus gems/firehose/test/"
  end
end

desc "Open console"
task :console do
  Dir.chdir("../..") do
    exec "bundle exec rails console"
  end
end
