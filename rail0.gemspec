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

  spec.required_ruby_version = ">= 2.6"

  spec.files         = Dir["lib/**/*.rb", "README.md", "LICENSE"]
  spec.require_paths = ["lib"]

  # No runtime dependencies — uses Ruby stdlib (net/http, json, openssl).
  # For off-chain EIP-3009 signing, add `gem 'eth', '~> 0.5'` to your Gemfile.
end
