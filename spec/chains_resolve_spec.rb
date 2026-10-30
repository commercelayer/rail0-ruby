# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Rail0::Resources::Chains.resolve" do
  let(:arc_test) { { chain_id: 5042002, slug: "arc", network_type: "testnet", public_rpc_urls: ["https://rpc.testnet.arc.network"] } }
  let(:arc_main) { { chain_id: 5042000, slug: "arc", network_type: "mainnet", public_rpc_urls: [] } }
  let(:base)     { { chain_id: 84532, slug: "base", network_type: "testnet", public_rpc_urls: [] } }
  let(:testnets) { [arc_test, base] }

  def resolve(chains, ref)
    Rail0::Resources::Chains.resolve(chains, ref)
  end

  it "resolves a slug case-insensitively" do
    expect(resolve(testnets, "ARC")).to eq(arc_test)
    expect(resolve(testnets, " base ")).to eq(base)
  end

  it "resolves a numeric chain id given as an Integer or a digit String" do
    expect(resolve(testnets, 84532)).to eq(base)
    expect(resolve(testnets, "5042002")).to eq(arc_test)
  end

  it "accepts string-keyed rows" do
    rows = testnets.map { |c| c.transform_keys(&:to_s) }
    expect(resolve(rows, "arc")[:chain_id]).to eq(5042002)
  end

  it "raises naming the available slugs when nothing matches" do
    expect { resolve(testnets, "monad") }
      .to raise_error(ArgumentError, /no chain with slug "monad" \(available slugs: arc, base\)/)
    expect { resolve(testnets, 1) }.to raise_error(ArgumentError, /no chain with id 1 \(available: arc, base\)/)
    expect { resolve([], "arc") }.to raise_error(ArgumentError, /available slugs: none/)
  end

  it "raises on a slug shared by several chains in the list" do
    expect { resolve([arc_test, arc_main, base], "arc") }
      .to raise_error(ArgumentError, /"arc" is ambiguous: it matches chains 5042002 \(testnet\), 5042000 \(mainnet\)/)
    expect(resolve([arc_test, arc_main], 5042000)).to eq(arc_main)
  end

  it "raises on a blank reference" do
    expect { resolve(testnets, nil) }.to raise_error(ArgumentError, /required/)
    expect { resolve(testnets, " ") }.to raise_error(ArgumentError, /required/)
  end
end
