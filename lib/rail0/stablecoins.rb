# frozen_string_literal: true

module Rail0
  # Stablecoin addresses and capabilities for supported EVM networks.
  #
  # eip3009 — transferWithAuthorization (Circle / USDC standard). Required by RAIL0.
  # eip2612 — permit (ERC-20 extension).
  # bridged  — bridge-wrapped variant that may not support either extension.
  module Stablecoins
    # Static metadata for a single stablecoin on a specific chain.
    StablecoinInfo = Struct.new(:address, :decimals, :eip3009, :eip2612, :bridged, keyword_init: true)

    # A chain's ID plus its token registry.
    ChainStablecoins = Struct.new(:chain_id, :tokens, keyword_init: true)

    # Token returned by {eip3009_tokens} and {eip2612_tokens}.
    StablecoinToken = Struct.new(:symbol, :address, :decimals, keyword_init: true)

    # Registry of known stablecoin addresses and capabilities across supported EVM chains.
    REGISTRY = {
      "ethereum" => ChainStablecoins.new(
        chain_id: 1,
        tokens: {
          "USDC"  => StablecoinInfo.new(address: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48", decimals: 6,  eip3009: true,  eip2612: false),
          "EURC"  => StablecoinInfo.new(address: "0x1aBaEA1f7C830bD89Acc67eC4af516284b1bC33c", decimals: 6,  eip3009: true,  eip2612: false),
          "PYUSD" => StablecoinInfo.new(address: "0x6c3ea9036406852006290770BEdFcAbA0e23A0e8", decimals: 6,  eip3009: true,  eip2612: false),
          "USDT"  => StablecoinInfo.new(address: "0xdAC17F958D2ee523a2206206994597C13D831ec7", decimals: 6,  eip3009: false, eip2612: false),
          "DAI"   => StablecoinInfo.new(address: "0x6B175474E89094C44Da98b954EedeAC495271d0F", decimals: 18, eip3009: false, eip2612: true)
        }
      ),
      "base" => ChainStablecoins.new(
        chain_id: 8453,
        tokens: {
          "USDC"  => StablecoinInfo.new(address: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913", decimals: 6, eip3009: true,  eip2612: false),
          "EURC"  => StablecoinInfo.new(address: "0x60a3E35Cc302bFA44Cb288Bc5a4F316Fdb1adb42", decimals: 6, eip3009: true,  eip2612: false),
          "USDbC" => StablecoinInfo.new(address: "0xd9aAEc86B65D86f6A7B5B1b0c42FFA531710b6CA", decimals: 6, eip3009: false, eip2612: false, bridged: true)
        }
      ),
      "polygon" => ChainStablecoins.new(
        chain_id: 137,
        tokens: {
          "USDC"   => StablecoinInfo.new(address: "0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359", decimals: 6,  eip3009: true,  eip2612: false),
          "USDC.e" => StablecoinInfo.new(address: "0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174", decimals: 6,  eip3009: true,  eip2612: false, bridged: true),
          "USDT"   => StablecoinInfo.new(address: "0xc2132D05D31c914a87C6611C10748AEb04B58e8F", decimals: 6,  eip3009: false, eip2612: false),
          "DAI"    => StablecoinInfo.new(address: "0x8f3Cf7ad23Cd3CaDbD9735AFf958023239c6A063", decimals: 18, eip3009: false, eip2612: false)
        }
      ),
      "arbitrumOne" => ChainStablecoins.new(
        chain_id: 42161,
        tokens: {
          "USDC"   => StablecoinInfo.new(address: "0xaf88d065e77c8cC2239327C5EDb3A432268e5831", decimals: 6,  eip3009: true,  eip2612: false),
          "USDC.e" => StablecoinInfo.new(address: "0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8", decimals: 6,  eip3009: false, eip2612: false, bridged: true),
          "USDT"   => StablecoinInfo.new(address: "0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9", decimals: 6,  eip3009: false, eip2612: false),
          "DAI"    => StablecoinInfo.new(address: "0xDA10009cBd5D07dd0CeCc66161FC93D7c9000da1", decimals: 18, eip3009: false, eip2612: true)
        }
      ),
      "optimism" => ChainStablecoins.new(
        chain_id: 10,
        tokens: {
          "USDC"   => StablecoinInfo.new(address: "0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85", decimals: 6,  eip3009: true,  eip2612: false),
          "USDC.e" => StablecoinInfo.new(address: "0x7F5c764cBc14f9669B88837ca1490cCa17c31607", decimals: 6,  eip3009: false, eip2612: false, bridged: true),
          "USDT"   => StablecoinInfo.new(address: "0x94b008aA00579c1307B0EF2c499aD98a8ce58e58", decimals: 6,  eip3009: false, eip2612: false),
          "DAI"    => StablecoinInfo.new(address: "0xDA10009cBd5D07dd0CeCc66161FC93D7c9000da1", decimals: 18, eip3009: false, eip2612: true)
        }
      ),
      "avalanche" => ChainStablecoins.new(
        chain_id: 43114,
        tokens: {
          "USDC"   => StablecoinInfo.new(address: "0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E", decimals: 6, eip3009: true,  eip2612: false),
          "USDC.e" => StablecoinInfo.new(address: "0xA7D7079b0FEaD91F3e65f86E8915Cb59c1a4C664", decimals: 6, eip3009: false, eip2612: false, bridged: true),
          "USDT"   => StablecoinInfo.new(address: "0x9702230A8Ea53601f5cD2dc00fDBc13d4dF4A8c7", decimals: 6, eip3009: false, eip2612: false)
        }
      ),
      "celo" => ChainStablecoins.new(
        chain_id: 42220,
        tokens: {
          "USDC" => StablecoinInfo.new(address: "0xcebA9300f2b948710d2De3250b7Ad3e4aFb0e50a", decimals: 6,  eip3009: true, eip2612: false),
          "cUSD" => StablecoinInfo.new(address: "0x765DE816845861e75A25fCA122bb6898B8B1282a", decimals: 18, eip3009: true, eip2612: false),
          "cEUR" => StablecoinInfo.new(address: "0xD8763CBa276a3738E6DE85b4b3bF5FDed6D6cA73", decimals: 18, eip3009: true, eip2612: false)
        }
      ),
      # ── Testnets ───────────────────────────────────────────────────────────
      # Every address below was read off its own chain, and the token lists are
      # the immutable acceptedTokens() allowlists of the RAIL0 deployments there
      # — which is what a payment on that chain can actually use.
      "arc-testnet" => ChainStablecoins.new(
        chain_id: 5042002,
        tokens: {
          "USDC" => StablecoinInfo.new(address: "0x3600000000000000000000000000000000000000", decimals: 6, eip3009: true, eip2612: true),
          "EURC" => StablecoinInfo.new(address: "0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a", decimals: 6, eip3009: true, eip2612: true)
        }
      ),
      # Celo Sepolia is 11142220. The rail0-go registry carried 44787 here, which is
      # ALFAJORES — a different, now-retired network — alongside a USDC address with
      # no code on this chain. Corrected there in the same change; do not "restore" it.
      "celo-sepolia" => ChainStablecoins.new(
        chain_id: 11142220,
        tokens: {
          "USDC" => StablecoinInfo.new(address: "0x01C5C0122039549AD1493B8220cABEdD739BC44E", decimals: 6, eip3009: true, eip2612: true),
          "USD₮" => StablecoinInfo.new(address: "0xd077A400968890Eacc75cdc901F0356c943e4fDb", decimals: 6, eip3009: true, eip2612: true)
        }
      ),
      # PYUSD is the first non-Circle token served, and the reason this chain is
      # served at all — it is issued nowhere else.
      #
      # Signing against PYUSD directly: its EIP-712 domain name is "PayPal USD", not
      # the symbol, and its version is "1", which version() does not expose (it
      # reverts). Through a RAIL0 payment this never bites — the domain comes down in
      # the gateway's signing_payload — but building the domain by hand from the
      # symbol yields a signature the token rejects.
      "ethereum-sepolia" => ChainStablecoins.new(
        chain_id: 11155111,
        tokens: {
          "USDC"  => StablecoinInfo.new(address: "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238", decimals: 6, eip3009: true, eip2612: true),
          "PYUSD" => StablecoinInfo.new(address: "0xCaC524BcA292aaade2DF8A05cC58F0a65B1B3bB9", decimals: 6, eip3009: true, eip2612: true)
        }
      )
    }.freeze

    # Returns the registry entry for a chain, or +nil+ if the chain is unknown.
    #
    # Supported chain names: "ethereum", "base", "polygon", "arbitrumOne",
    # "optimism", "avalanche", "celo", "arc-testnet", "celo-sepolia",
    # "ethereum-sepolia".
    #
    # @param chain [String]
    # @return [ChainStablecoins, nil]
    def self.chain_info(chain)
      REGISTRY[chain]
    end

    # Returns all tokens on a chain that support EIP-3009 (transferWithAuthorization).
    # These are the tokens compatible with RAIL0.
    #
    # @param chain [String]
    # @return [Array<StablecoinToken>]
    def self.eip3009_tokens(chain)
      tokens_supporting(chain, :eip3009)
    end

    # Returns all tokens on a chain that support EIP-2612 (permit).
    #
    # @param chain [String]
    # @return [Array<StablecoinToken>]
    def self.eip2612_tokens(chain)
      tokens_supporting(chain, :eip2612)
    end

    def self.tokens_supporting(chain, capability)
      c = REGISTRY[chain] or return []
      c.tokens.each_with_object([]) do |(symbol, info), arr|
        if info.public_send(capability)
          arr << StablecoinToken.new(symbol: symbol, address: info.address, decimals: info.decimals)
        end
      end
    end

    private_class_method :tokens_supporting
  end
end
