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

# `bundler/gem_tasks` above gives build / install / release, and the gate hangs off BUILD
# rather than off release. That is the whole point, and it is not a style choice:
#
# Rake runs prerequisites in declaration order, and re-declaring a task APPENDS to that
# list. `task release: :default` therefore put the gate LAST -- after
# release:rubygem_push -- so rubocop and the suite ran once the gem was already on
# rubygems.org. It read like a gate and gated nothing.
#
# `build` is release's FIRST prerequisite, so gating build puts rubocop + spec ahead of
# guard_clean, ahead of the tag push and ahead of the gem push. Rake runs a task once, so
# nothing repeats. `rake install` inherits it too, which is right: packaging a gem the
# suite has not seen is the thing worth refusing.
#
# Verify with `rake -P`: `default` must appear under `rake build`, not at the end of
# `rake release`.
task build: :default

# Releases ship from CI only: bin/release-prepare opens the release pull request, and
# merging it runs .github/workflows/release.yml (RubyGems Trusted Publishing, then the
# tag). bundler's `rake release` — tag, push and `gem push` from a laptop — would bypass
# the review, so it and its release:* steps are replaced by a pointer.
Rake::Task.tasks.each { |t| t.clear if t.name == "release" || t.name.start_with?("release:") }
desc "Disabled: run bin/release-prepare and merge the release pull request"
task :release do
  abort "rake release is disabled: run bin/release-prepare, then get the release pull " \
        "request approved and merge it (.github/workflows/release.yml publishes the gem)."
end
