RSpec.describe Rail0::Stablecoins do
  describe ".chain_info" do
    it "returns chain data for a known chain" do
      info = Rail0::Stablecoins.chain_info("base")
      expect(info).not_to be_nil
      expect(info.chain_id).to eq(8453)
      expect(info.tokens).to have_key("USDC")
    end

    it "returns nil for an unknown chain" do
      expect(Rail0::Stablecoins.chain_info("unknown")).to be_nil
    end
  end

  describe ".eip3009_tokens" do
    it "returns EIP-3009 tokens for base" do
      tokens = Rail0::Stablecoins.eip3009_tokens("base")
      symbols = tokens.map(&:symbol)
      expect(symbols).to include("USDC", "EURC")
      expect(symbols).not_to include("USDbC")
    end

    it "returns an empty array for an unknown chain" do
      expect(Rail0::Stablecoins.eip3009_tokens("unknown")).to eq([])
    end

    it "returns token structs with address and decimals" do
      tokens = Rail0::Stablecoins.eip3009_tokens("base")
      usdc = tokens.find { |t| t.symbol == "USDC" }
      expect(usdc.address).to eq("0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913")
      expect(usdc.decimals).to eq(6)
    end
  end

  describe ".eip2612_tokens" do
    it "returns EIP-2612 tokens for ethereum" do
      tokens = Rail0::Stablecoins.eip2612_tokens("ethereum")
      expect(tokens.map(&:symbol)).to include("DAI")
    end

    it "returns an empty array for an unknown chain" do
      expect(Rail0::Stablecoins.eip2612_tokens("unknown")).to eq([])
    end
  end

  describe "REGISTRY" do
    it "covers all 7 chains" do
      expect(Rail0::Stablecoins::REGISTRY.keys).to match_array(
        %w[ethereum base polygon arbitrumOne optimism avalanche celo]
      )
    end
  end
end
