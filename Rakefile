# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"
require "rubocop/rake_task"

RSpec::Core::RakeTask.new(:spec)
RuboCop::RakeTask.new(:rubocop)

# The CI gate runs `bundle exec rake`, so both live here rather than in the workflow: a
# contributor running `rake` locally gets exactly what CI will say.
#
# Style FIRST, deliberately: it is the faster of the two and its failures are the cheaper to
# act on, so a formatting slip does not wait behind the suite.
task default: %i[rubocop spec]

# `bundler/gem_tasks` above gives build / install / release. Release is gated on the
# default task, so a publish cannot happen from a tree that rubocop or the suite would
# reject -- the same rule rail0-ts follows with prepublishOnly, for the same reason: the
# gate is worth nothing if the one operation that cannot be undone skips it.
#
# Re-declaring the task ADDS a prerequisite rather than replacing bundler's own.
task release: :default
