# frozen_string_literal: true

# The gem is "rail0-sdk"; its entry point is `rail0`.
#
# This file is not cosmetic. Bundler requires a gem by its OWN name by default, so
# `gem "rail0-sdk"` in a Gemfile with Bundler.require raises LoadError without it. It also
# gives anyone who reaches for the name they installed the file they expect.
#
# The canonical path stays `rail0`, unchanged: it is what every existing caller, example and
# integration test requires, and what the Rail0 module is named after.
require_relative "rail0"
