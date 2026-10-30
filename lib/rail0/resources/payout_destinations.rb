# frozen_string_literal: true

require_relative "query"

module Rail0
  module Resources
    # Payout destinations: where a merchant wallet sends its balance — a deposit address at
    # an exchange, Circle Mint, an off-ramp provider or the merchant's own custody (JWT,
    # merchant session).
    #
    # A destination is registered +unverified+. It becomes +verified+ after a small PROOF
    # transfer ({Payouts#prepare} with +purpose: "proof"+) has confirmed on-chain AND the
    # merchant has checked the venue credited it ({#confirm}). Until then it can receive the
    # proof amount at most. See {Payouts} for the transfer itself.
    #
    # Amounts on a destination (+reserve_amount+, +min_amount+) are BASE-UNIT strings (digits
    # only, below 2^120); the +*_formatted+ fields beside them carry the human decimals.
    class PayoutDestinations
      # The default of {update}'s keywords: "not passed", told apart from an explicit value.
      UNSET = Object.new.freeze
      private_constant :UNSET

      include Query

      # The text of the gateway's +details_v1+ attestation, which +confirm_details: true+
      # stands for on {create} and on an {update} that changes +min_amount+. Show it to the
      # merchant and send +confirm_details: true+ only once they have accepted it.
      CONFIRM_DETAILS_TEXT =
        "I have checked the address, network, token and minimum deposit on the venue's deposit " \
        "page and confirm they are correct. Funds sent to a wrong address or network, or below " \
        "the venue's minimum, may be permanently lost and cannot be recovered by rail0."

      # The venue kinds a destination can be registered as.
      KINDS = %w[exchange circle_mint self_custody provider].freeze

      # A destination's statuses — the values {list}'s +status+ filter accepts.
      STATUSES = %w[unverified verified disabled].freeze

      attr_reader :http

      def initialize(http)
        @http = http
        freeze
      end

      # List the account's payout destinations (every wallet of the account).
      # @param wallet_id [String, nil] Only this wallet's destinations (uuid).
      # @param status [String, nil] One of {STATUSES}.
      # @param sort [String, nil] Comma-separated sort fields; prefix with - for desc.
      # @param page [Integer, nil] Page number (1-based).
      # @param per_page [Integer, nil] Items per page (max 100).
      # @return [Hash] { data: Array<Hash>, meta: { page:, per_page:, total:, total_pages:, links: } }
      def list(wallet_id: nil, status: nil, sort: nil, page: nil, per_page: nil)
        query = build_query(wallet_id: wallet_id, status: status, sort: sort, page: page, per_page: per_page)
        http.get_list("/payout_destinations#{query}")
      end

      # Register a payout destination for the session's own wallet. Answers 201 with the
      # destination, +unverified+.
      #
      # +confirm_details+ is REQUIRED and has no default on purpose: +true+ is the merchant's
      # attestation of {CONFIRM_DETAILS_TEXT} (the gateway's +details_v1+) —
      #
      #   "I have checked the address, network, token and minimum deposit on the venue's
      #   deposit page and confirm they are correct. Funds sent to a wrong address or network,
      #   or below the venue's minimum, may be permanently lost and cannot be recovered by
      #   rail0."
      #
      # — recorded with who and when in the +destination.created+ event. Anything but +true+ is
      # refused 422 +confirmation_required+ and nothing is saved. Pass the merchant's answer,
      # never a hard-coded +true+.
      #
      # +min_amount+ is REQUIRED too, with no default on purpose: the venue's deposit minimum
      # as the merchant read it on the venue's deposit page, or +"0"+ when the venue has none.
      # Left out or blank, the gateway refuses it 422 +minimum_required+ — a minimum nobody
      # looked up is how a deposit gets lost, so never fill it in with a hard-coded +"0"+.
      #
      # @param wallet_id [String] The wallet (uuid or address) that will sign transfers to it;
      #   must be the session's own.
      # @param chain_id [Integer] The chain the deposit address was issued for.
      # @param token [String] The token's address on that chain.
      # @param address [String] The deposit address, generated at the venue WITH THE NETWORK
      #   SET TO THIS CHAIN.
      # @param confirm_details [Boolean] The merchant's acceptance of {CONFIRM_DETAILS_TEXT}.
      # @param min_amount [String] The venue's deposit minimum in base units, +"0"+ when the
      #   venue has none. A payout below it is refused (+payout_below_minimum+) and the proof
      #   is raised to it.
      # @param label [String, nil] A name for the destination.
      # @param kind [String, nil] One of {KINDS}; the gateway defaults to "exchange".
      # @param reserve_amount [String, nil] Base units to keep in the wallet on a full-balance
      #   ("all") payout; omitted, the gateway's suggestion (the refundable balance still
      #   inside its refund window) applies.
      # @return [Hash] The destination.
      def create(wallet_id:, chain_id:, token:, address:, confirm_details:, min_amount:, label: nil, kind: nil,
                 reserve_amount: nil)
        body = { wallet_id: wallet_id, chain_id: chain_id, token: token, address: address,
                 confirm_details: confirm_details, label: label, kind: kind,
                 reserve_amount: reserve_amount, min_amount: min_amount }.compact
        http.post("/payout_destinations", body)
      end

      # Read one destination (any wallet of the account may).
      # @param id [String] Destination uuid.
      # @return [Hash]
      def get(id)
        http.get("/payout_destinations/#{segment(id)}")
      end

      # Update a destination. Only the keywords you PASS are sent, and at least one is
      # required (ArgumentError otherwise).
      #
      # - +reserve_amount+: base units; an empty string restores the suggestion.
      # - +min_amount+: base units, +"0"+ when the venue has no minimum (that is how a minimum
      #   is removed). Never blank: an empty string is refused 422 +minimum_required+. A
      #   destination registered before the minimum was required may hold none (+nil+): it
      #   sends nothing (422 +payout_destination_minimum_unset+ on prepare and submit) until
      #   one is set here.
      # - A request that CHANGES +min_amount+ also needs +confirm_details: true+ — the same
      #   attestation as {create} ({CONFIRM_DETAILS_TEXT}), else 422 +confirmation_required+
      #   and nothing is written. Raising the minimum above the destination's latest proof
      #   takes its verification away: prove it again with a new proof.
      # - +active: false+ disables it (any wallet of the account may); its unsigned pending
      #   payout is cancelled, a signed one refuses the switch-off 409 +payout_already_signed+.
      #   +active: true+ re-enables it with the verification it had.
      #
      # @param id [String] Destination uuid.
      # @return [Hash] The destination.
      def update(id, label: UNSET, reserve_amount: UNSET, min_amount: UNSET, active: UNSET,
                 confirm_details: UNSET)
        body = { label: label, reserve_amount: reserve_amount, min_amount: min_amount, active: active,
                 confirm_details: confirm_details }.reject { |_, v| v.equal?(UNSET) }
        if body.except(:confirm_details).empty?
          raise ArgumentError, "at least one of label, reserve_amount, min_amount or active is required"
        end

        http.patch("/payout_destinations/#{segment(id)}", body)
      end

      # The merchant's attestation that the venue CREDITED the proof transfer: marks the
      # destination +verified+. The proof payout must be +confirmed+ on-chain first (422
      # +payout_destination_proof_missing+ otherwise).
      # @param id [String] Destination uuid.
      # @return [Hash] The destination, now verified.
      def confirm(id)
        http.post("/payout_destinations/#{segment(id)}/confirm")
      end

      # The destination's audit trail, newest first: its own events and those of every
      # payout made to it (+destination.created+, +payout.prepared+, +payout.confirmed+, …).
      # @param id [String] Destination uuid.
      # @param page [Integer, nil] Page number (1-based).
      # @param per_page [Integer, nil] Items per page (default 25, max 100).
      # @return [Hash] { data: Array<Hash>, meta: { ... } }
      def events(id, page: nil, per_page: nil)
        http.get_list("/payout_destinations/#{segment(id)}/events#{build_query(page: page, per_page: per_page)}")
      end
    end
  end
end
