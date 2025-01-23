# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name = "discourse-systray"
  spec.version = "0.1.0"
  spec.authors = ["Your Name"]
  spec.email = ["your.email@example.com"]

  spec.summary = "System tray application for managing Discourse development"
  spec.description = "A GTK3 system tray application that helps manage local Discourse development instances"
  spec.homepage = "https://github.com/yourusername/discourse-systray"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 2.6.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage

  spec.files = Dir.glob("{bin,lib,assets}/**/*") + %w[README.md LICENSE.txt]
  spec.bindir = "bin"
  spec.executables = ["discourse-systray"]
  
  spec.add_dependency "gtk3", "~> 3.4"
  
  spec.add_development_dependency "bundler", "~> 2.0"
  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "rspec", "~> 3.0"
end
