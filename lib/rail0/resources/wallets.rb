# frozen_string_literal: true

require_relative "query"

module Rail0
  module Resources
    # Account-scoped wallet management (requires JWT).
    #
    # Wallets live under /accounts/{account_id}/wallets, so every method takes the
    # account id as its first argument. +list+ returns the account's wallets, each
    # with its token holdings nested under +tokens+ (a wallet with no matching
    # tokens is still returned with an empty list). +id_or_address+ accepts either
    # the wallet UUID or its 0x address (unique per account).
    class Wallets
      include Query

      def initialize(http)
        @http = http
      end

      # List the account's wallets, each with nested token holdings.
      # @param account_id [String] Account UUID.
      # @param chain_id [Integer, nil] Restrict nested tokens to this chain id.
      # @param token_symbol [String, nil] Restrict nested tokens to this symbol (e.g. "USDC").
      # @param active [Boolean, nil] Filter wallets by active flag.
      # @param default [Boolean, nil] Restrict nested holdings to the default one.
      # @param sort [String, nil] Comma-separated sort fields; prefix with - for desc.
      # @param page [Integer, nil] Page number (1-based).
      # @param per_page [Integer, nil] Items per page (max 100).
      # @return [Hash] { data: Array<Hash>, meta: { page:, per_page:, total: } }
      def list(account_id, chain_id: nil, token_symbol: nil, active: nil, default: nil,
               sort: nil, page: nil, per_page: nil)
        query = build_query(chain_id: chain_id, token_symbol: token_symbol, active: active,
                            default: default, sort: sort, page: page, per_page: per_page)
        @http.get_list("/accounts/#{account_id}/wallets#{query}")
      end

      # Fetch a single wallet by its id or 0x address.
      # @param account_id [String] Account UUID.
      # @param id_or_address [String] Wallet UUID or 0x address.
      # @return [Hash] id, address, label, active
      def get(account_id, id_or_address)
        @http.get("/accounts/#{account_id}/wallets/#{id_or_address}")
      end

      # Add a wallet to the account.
      # @param account_id [String] Account UUID.
      # @param address [String] EVM wallet address (0x, 42 chars).
      # @param label [String, nil] Human-readable label.
      # @return [Hash] id, address, label, active
      def create(account_id, address:, label: nil)
        body = { address: address }
        body[:label] = label unless label.nil?
        @http.post("/accounts/#{account_id}/wallets", body)
      end

      # Update a wallet's label and/or active status.
      # @param account_id [String] Account UUID.
      # @param id_or_address [String] Wallet UUID or 0x address.
      # @param label [String, nil] New label.
      # @param active [Boolean, nil] New active status.
      # @return [Hash] id, address, label, active
      def update(account_id, id_or_address, label: nil, active: nil)
        body = {}
        body[:label]  = label  unless label.nil?
        body[:active] = active unless active.nil?
        @http.patch("/accounts/#{account_id}/wallets/#{id_or_address}", body)
      end

      # Soft-delete (deactivate) a wallet. Returns HTTP 204.
      # @param account_id [String] Account UUID.
      # @param id_or_address [String] Wallet UUID or 0x address.
      # @return [nil]
      def delete(account_id, id_or_address)
        @http.delete("/accounts/#{account_id}/wallets/#{id_or_address}")
      end

      # Read a wallet's live on-chain balances across the configured chains. Each
      # per-chain entry carries the native gas-token balance plus the active ERC-20
      # token balances, or an in-band error when that chain's RPC was unreachable
      # (one dead RPC never hides the other chains' balances).
      # @param account_id [String] Account UUID.
      # @param id_or_address [String] Wallet UUID or 0x address.
      # @param chain_id [Integer, nil] Restrict to one chain id (default: all configured chains).
      # @param token_symbol [String, nil] Restrict tokens to this symbol (default: all active tokens).
      # @return [Hash] wallet_id, address, balances
      def balances(account_id, id_or_address, chain_id: nil, token_symbol: nil)
        query = build_query(chain_id: chain_id, token_symbol: token_symbol)
        @http.get("/accounts/#{account_id}/wallets/#{id_or_address}/balances#{query}")
      end
    end
  end
end
