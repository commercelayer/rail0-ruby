# frozen_string_literal: true

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
    it "covers the 7 mainnets and the 3 testnets" do
      expect(Rail0::Stablecoins::REGISTRY.keys).to match_array(
        %w[ethereum base polygon arbitrumOne optimism avalanche celo
           arc-testnet celo-sepolia ethereum-sepolia]
      )
    end
  end

  # Pinned address by address: a wrong entry here is invisible from Ruby — a caller
  # looking one up to sign against gets a plausible answer either way. rail0-go
  # carried Alfajores' chain id (44787) under "celo-sepolia" with a USDC address that
  # has no code on that chain, and nothing caught it.
  describe "testnet entries" do
    {
      "arc-testnet" => [5042002, {
        "USDC" => "0x3600000000000000000000000000000000000000",
        "EURC" => "0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a"
      }],
      "celo-sepolia" => [11_142_220, {
        "USDC" => "0x01C5C0122039549AD1493B8220cABEdD739BC44E",
        "USD₮" => "0xd077A400968890Eacc75cdc901F0356c943e4fDb"
      }],
      "ethereum-sepolia" => [11_155_111, {
        "USDC"  => "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238",
        "PYUSD" => "0xCaC524BcA292aaade2DF8A05cC58F0a65B1B3bB9"
      }]
    }.each do |chain, (chain_id, tokens)|
      it "pins #{chain}" do
        info = Rail0::Stablecoins.chain_info(chain)
        expect(info).not_to be_nil
        expect(info.chain_id).to eq(chain_id)
        expect(info.tokens.keys).to match_array(tokens.keys)
        tokens.each do |symbol, address|
          expect(info.tokens[symbol].address).to eq(address)
          expect(info.tokens[symbol].decimals).to eq(6)
          # RAIL0 pulls funds with receiveWithAuthorization, so a token that is not
          # EIP-3009 cannot be paid with and must never be listed as payable.
          expect(info.tokens[symbol].eip3009).to be true
        end
      end
    end

    # PYUSD is the first non-Circle token served: it is what proves the registry is
    # not implicitly a USDC list.
    it "exposes PYUSD as an EIP-3009 token on ethereum-sepolia" do
      symbols = Rail0::Stablecoins.eip3009_tokens("ethereum-sepolia").map(&:symbol)
      expect(symbols).to include("PYUSD")
    end
  end

  describe "StablecoinInfo#bridged" do
    it "is true for a known bridge-wrapped token" do
      info = Rail0::Stablecoins.chain_info("base").tokens["USDbC"]
      expect(info.bridged).to be true
    end

    it "is falsy for a non-bridged token" do
      info = Rail0::Stablecoins.chain_info("base").tokens["USDC"]
      expect(info.bridged).to be_falsy
    end
  end
end
