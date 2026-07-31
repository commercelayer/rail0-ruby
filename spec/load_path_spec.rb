# frozen_string_literal: true

require "spec_helper"

# Loading this SDK must not change how the HOST application resolves requires.
#
# `require "rail0"` used to unshift lib/rail0 and lib/rail0/resources onto the
# global $LOAD_PATH so the gem's files could require each other by bare name.
# That left ~20 generic basenames — request, client, query, version, types, auth,
# payments … — at the FRONT of the search path for the rest of the process, so any
# gem loaded afterwards doing a bare `require "request"` silently got ours. The
# collision is order-dependent and produces no warning, which is what made it
# unsafe to embed in a large Rails app. (#5)
RSpec.describe "load path hygiene" do
  let(:gem_lib)   { File.expand_path("../lib", __dir__) }
  let(:internals) { [File.join(gem_lib, "rail0"), File.join(gem_lib, "rail0", "resources")] }

  it "does not put the gem's internal directories on the global $LOAD_PATH" do
    # spec_helper has already required rail0, so this reflects the post-load state.
    expect($LOAD_PATH).not_to include(*internals)
  end

  # The consequence, asserted directly rather than through the path: a host app
  # asking for a common basename must not be handed one of ours.
  it "does not make the gem's files requirable by their bare basename" do
    %w[query request client version types api_error payments auth].each do |basename|
      expect { require basename }.to raise_error(LoadError),
                                     "`require #{basename.inspect}` must not resolve into this gem"
    end
  end

  # The public entry points stay reachable — they are namespaced under rail0/,
  # which the gemspec's require_paths already covers.
  it "still loads its public entry points by their namespaced name" do
    expect { require "rail0" }.not_to raise_error
    expect { require "rail0/signing" }.not_to raise_error
    expect(defined?(Rail0::Client)).to eq("constant")
    expect(defined?(Rail0::Signing)).to eq("constant")
  end
end
