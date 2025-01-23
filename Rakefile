require "bundler/gem_tasks"
require "rspec/core/rake_task"
require "fileutils"

RSpec::Core::RakeTask.new(:spec)

task :default => [:spec, :build]

desc "Clean built gems"
task :clean do
  FileUtils.rm_f Dir.glob("*.gem")
end

desc "Build the gem"
task :build => [:clean] do
  system "gem build discourse-systray.gemspec"
end

desc "Run the application in development" 
task :run do
  ruby "exe/run"
end

# Override the release task to clean up after
Rake::Task["release"].enhance do
  Rake::Task["clean"].invoke
end
