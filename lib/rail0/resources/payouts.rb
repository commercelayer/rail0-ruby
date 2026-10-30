# frozen_string_literal: true

require_relative "query"

module Rail0
  module Resources
    # Merchant payouts: an ERC-20 transfer of the wallet's balance to one of its
    # {PayoutDestinations} (JWT, merchant session; the destination's own wallet signs).
    #
    # Two-phase like the payment operations. {prepare} builds the unsigned EIP-1559
    # transaction — a +transfer(address,uint256)+ on the TOKEN contract — and answers the
    # pending payout with it in +unsigned_transaction+. Then either:
    #
    # - sign it offline and {submit} the raw bytes (the gateway broadcasts them) — or do
    #   both with {sign_and_submit}, which VERIFIES the transaction before signing; or
    # - broadcast it yourself (a wallet that signs and sends in one step) and report the
    #   hash with {submit_by_hash}.
    #
    # The payout then settles asynchronously: poll {get} until +status+ is +confirmed+ or
    # +failed+, or subscribe to the +payouts.confirmed+ / +payouts.failed+ webhooks.
    #
    # Amounts: +prepare+'s +amount+ is a HUMAN decimal ("250.00") or "all" (the balance
    # minus the destination's reserve); the payout record's +amount+ is base units, with
    # +amount_formatted+ beside it.
    class Payouts
      include Query

      # What a payout is for: "proof" (the small test transfer that verifies a
      # destination) or "payout" (the default).
      PURPOSES = %w[payout proof].freeze

      # A payout's statuses — the values {list}'s +status+ filter accepts.
      STATUSES = %w[pending submitted confirmed failed].freeze

      attr_reader :http

      def initialize(http)
        @http = http
        freeze
      end

      # List the account's payouts, newest first by default.
      # @param destination_id [String, nil] Only payouts to this destination (uuid).
      # @param wallet_id [String, nil] Only this wallet's payouts (uuid).
      # @param status [String, Array<String>, nil] One of {STATUSES}, or an Array matching
      #   ANY of them (sent comma-separated).
      # @param purpose [String, nil] One of {PURPOSES}.
      # @param created_from [String, nil] Only payouts created at/after this ISO-8601 time.
      # @param created_to [String, nil] Only payouts created at/before this ISO-8601 time.
      # @param sort [String, nil] Comma-separated sort fields; prefix with - for desc.
      # @param page [Integer, nil] Page number (1-based).
      # @param per_page [Integer, nil] Items per page (default 25, max 100).
      # @param after [String, nil] Cursor paging, as on {Payments#list}: the previous page's
      #   `meta[:next_cursor]`; no total, and not combinable with `page:` or another sort.
      # @return [Hash] { data: Array<Hash>, meta: { page:, per_page:, total:, total_pages:, links:,
      #   next_cursor: } }
      def list(destination_id: nil, wallet_id: nil, status: nil, purpose: nil, created_from: nil,
               created_to: nil, sort: nil, page: nil, per_page: nil, after: nil)
        query = build_query(destination_id: destination_id, wallet_id: wallet_id, status: status,
                            purpose: purpose, created_from: created_from, created_to: created_to,
                            sort: sort, page: page, per_page: per_page, after: after)
        http.get_list("/payouts#{query}")
      end

      # Prepare a transfer to a destination (POST /payouts/prepare): 201 with a new pending
      # payout, or 200 re-preparing the destination's unsigned pending one (one pending
      # payout per destination). Its +unsigned_transaction+ is what to sign.
      #
      # - +purpose: "proof"+ sends the gateway's proof amount, raised to the destination's
      #   +min_amount+ when that is higher; +amount+ is ignored. An unverified destination
      #   may receive the proof at most.
      # - +purpose: "payout"+ (the default) sends +amount+: a human decimal, or "all" for
      #   the balance minus the reserve. Below the destination's +min_amount+ it is refused
      #   422 +payout_below_minimum+.
      # - A payout that already holds a signed transaction cannot be re-prepared (409
      #   +payout_already_signed+): {resend} it, or let it settle.
      #
      # @param destination_id [String] Destination uuid.
      # @param purpose [String, nil] One of {PURPOSES}; the gateway defaults to "payout".
      # @param amount [String, nil] Human decimal or "all"; required for a payout.
      # @return [Hash] The pending payout.
      def prepare(destination_id:, purpose: nil, amount: nil)
        body = { destination_id: destination_id, purpose: purpose, amount: amount }.compact
        http.post("/payouts/prepare", body)
      end

      # Read one payout.
      # @param id [String] Payout uuid.
      # @return [Hash]
      def get(id)
        http.get("/payouts/#{segment(id)}")
      end

      # The payout's audit trail, newest first.
      # @param id [String] Payout uuid.
      # @param page [Integer, nil] Page number (1-based).
      # @param per_page [Integer, nil] Items per page (default 25, max 100).
      # @return [Hash] { data: Array<Hash>, meta: { ... } }
      def events(id, page: nil, per_page: nil)
        http.get_list("/payouts/#{segment(id)}/events#{build_query(page: page, per_page: per_page)}")
      end

      # Submit the signed transfer; the gateway stores it, then broadcasts it (HTTP 202,
      # now +submitted+). A node refusal answers 502 and leaves the payout +pending+ with
      # its signature: {resend} it. Prefer {sign_and_submit}, which verifies before signing.
      # @param id [String] Payout uuid.
      # @param params [Hash] { signed_transaction: "0x…" }.
      # @return [Hash] The payout.
      def submit(id, params)
        http.post("/payouts/#{segment(id)}/submit", params)
      end

      # Verify, sign and submit a prepared payout in one call.
      #
      # {Rail0::Signing.sign_payout} first holds the +unsigned_transaction+ to the payout —
      # +to+ the token, value 0, the payout's chain, calldata exactly
      # +transfer(destination address, payout amount)+, nothing trailing — and, when given,
      # to the registered +destination:+ and to the +amount:+ you asked prepare for (scaled
      # by +decimals:+). Anything else raises {Rail0::TxVerify::RefusedSignature} and
      # nothing is signed or sent. Then {submit}.
      #
      #   destination = client.payout_destinations.get(destination_id)
      #   payout = client.payouts.prepare(destination_id: destination_id, amount: "250.00")
      #   client.payouts.sign_and_submit(payout, MERCHANT_PRIVATE_KEY, destination: destination,
      #                                  amount: "250.00", decimals: 6)
      #
      # Needs the optional +eth+ gem (loaded here, not by +require "rail0"+).
      #
      # @param payout [Hash] The prepared payout (from {prepare} or {get}).
      # @param private_key [String, Eth::Key] The destination wallet's key.
      # @param destination [Hash, nil] The destination the payout must be for.
      # @param amount [String, nil] The human decimal passed to prepare (not "all").
      # @param decimals [Integer, nil] The token's decimals, required with +amount:+.
      # @return [Hash] The payout, now +submitted+.
      def sign_and_submit(payout, private_key, destination: nil, amount: nil, decimals: nil)
        require_relative "../signing"

        raw = Rail0::Signing.sign_payout(payout, private_key, destination: destination,
                                                              amount: amount, decimals: decimals)
        submit(payout[:id] || payout["id"], { signed_transaction: raw })
      end

      # Re-broadcast the signed transaction a {submit} stored (no body): the same bytes, so
      # the same nonce and hash. For a submit whose broadcast was refused or went
      # unanswered (422 +payout_not_signed+ when there is nothing to resend).
      # @param id [String] Payout uuid.
      # @return [Hash] The payout.
      def resend(id)
        http.post("/payouts/#{segment(id)}/resend")
      end

      # Cancel an UNSIGNED pending payout: it becomes +failed+ with +error_code+ "cancelled"
      # and the destination is free for a new prepare. A signed one is refused 409
      # +payout_already_signed+ — its transaction may still be mined.
      # @param id [String] Payout uuid.
      # @return [Hash] The payout.
      def cancel(id)
        http.post("/payouts/#{segment(id)}/cancel")
      end

      # Report a transfer the wallet broadcast itself, by hash (POST /payouts/{id}/submitted,
      # HTTP 202). The hash must be THIS transfer — from the wallet, on the token, this amount
      # to this destination — or 422 +foreign_transfer_hash+. Also accepts a LATE hash on a
      # payout that failed +submission_timeout+ or +dropped+.
      # @param id [String] Payout uuid.
      # @param params [Hash] { transaction_hash: "0x…" }.
      # @return [Hash] The payout, now +submitted+.
      def submit_by_hash(id, params)
        http.post("/payouts/#{segment(id)}/submitted", params)
      end
    end
  end
end
