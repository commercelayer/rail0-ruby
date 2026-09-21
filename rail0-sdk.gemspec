# frozen_string_literal: true

require_relative "lib/rail0/version"

Gem::Specification.new do |spec|
  # "rail0-sdk", not "rail0": RubyGems has one global namespace, and this is the SDK
  # rather than the protocol. The require path stays `rail0` (see lib/rail0-sdk.rb for
  # the shim that makes the gem's own name requirable too).
  spec.name     = "rail0-sdk"
  spec.version  = Rail0::VERSION
  spec.summary  = "Ruby SDK for the RAIL0 stablecoin payment protocol"
  spec.description = <<~DESC
    REST client for the RAIL0 stablecoin payment API. Wraps the authorize →
    capture → refund lifecycle with full type documentation, retry support,
    pluggable logging, and optional off-chain EIP-3009 signing.
  DESC
  spec.authors  = ["Commerce Layer"]
  spec.license  = "MIT"
  spec.homepage = "https://github.com/commercelayer/rail0-ruby"

  spec.required_ruby_version = ">= 3.0"

  # The links RubyGems shows beside the gem. Without them the page offers only the
  # homepage, and "where do I file this" is the first question a published gem gets.
  # No homepage_uri here: spec.homepage already supplies it, and naming the same URL
  # twice makes `gem build` warn that only the first of the two is ever shown.
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["bug_tracker_uri"] = "#{spec.homepage}/issues"
  spec.metadata["changelog_uri"]   = "#{spec.homepage}/releases"

  # Not a default gem since Ruby 4.0; required by lib/rail0/default_logger.rb.
  spec.add_dependency "logger", "~> 1.6"

  spec.files         = Dir["lib/**/*.rb", "README.md", "LICENSE"]
  spec.require_paths = ["lib"]

  # No runtime dependencies — uses Ruby stdlib (net/http, json, openssl).
  # For off-chain EIP-3009 signing and SIWE authentication (client.auth.login),
  # add to your Gemfile:
  #   gem 'eth',     '~> 0.5'
  #   gem 'siwe-rb', '~> 0.2'
  spec.metadata["rubygems_mfa_required"] = "true"
end
