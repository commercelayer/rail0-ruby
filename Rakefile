# frozen_string_literal: true

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
