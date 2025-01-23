require "bundler/gem_tasks"
require "rspec/core/rake_task"

RSpec::Core::RakeTask.new(:spec)

task :default => [:spec, :build]

desc "Build the gem"
task :build do
  system "gem build discourse-systray.gemspec"
end

desc "Run the application in development"
task :run do
  ruby "exe/run"
end
