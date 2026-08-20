# frozen_string_literal: true

source "https://rubygems.org"

gemspec

group :development do
  gem "eth",     "~> 0.5"
  gem "rake",    "~> 13.0"
  gem "rspec",   "~> 3.13"
  gem "siwe-rb", "~> 0.2"
  gem "webmock", "~> 3.23"
  # Style gate. Added late, so .rubocop.yml calibrates the cops to the code that already
  # exists rather than the code rubocop would prefer — see the comments there.
  gem "rubocop",       "~> 1.66", require: false
  gem "rubocop-rspec", "~> 3.0",  require: false
end
