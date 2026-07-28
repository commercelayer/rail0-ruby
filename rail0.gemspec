require_relative "lib/rail0/version"

Gem::Specification.new do |spec|
  spec.name     = "rail0"
  spec.version  = Rail0::VERSION
  spec.summary  = "Ruby SDK for the RAIL0 stablecoin payment protocol"
  spec.description = <<~DESC
    REST client for the RAIL0 stablecoin payment API. Wraps the authorize →
    capture → refund lifecycle with full type documentation, retry support,
    pluggable logging, and optional off-chain EIP-3009 signing.
  DESC
  spec.authors  = ["RAIL0"]
  spec.license  = "MIT"

  spec.required_ruby_version = ">= 3.0"

  # `logger` left the default gems in Ruby 4.0, and lib/rail0/default_logger.rb requires
  # it at load time — so without this declaration the SDK cannot be loaded at all under
  # bundler on a Ruby this gemspec says it supports. Declared as a runtime dependency
  # rather than pinned in the Gemfile because it is the library that needs it, not the
  # test setup.
  spec.add_dependency "logger", "~> 1.6"

  spec.files         = Dir["lib/**/*.rb", "README.md", "LICENSE"]
  spec.require_paths = ["lib"]

  # No runtime dependencies — uses Ruby stdlib (net/http, json, openssl).
  # For off-chain EIP-3009 signing and SIWE authentication (client.auth.login),
  # add to your Gemfile:
  #   gem 'eth',     '~> 0.5'
  #   gem 'siwe-rb', '~> 0.2'
end
