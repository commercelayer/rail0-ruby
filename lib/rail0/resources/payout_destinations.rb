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
    # Amounts on a destination (+min_amount+) are BASE-UNIT strings (digits only, below
    # 2^120); the +*_formatted+ fields beside them carry the human decimals. What a payout
    # keeps back in the wallet (the refund and gas reserves) is decided at payout time, not
    # stored on the destination: see {#reserves} and {Payouts#prepare}.
    class PayoutDestinations
      # The default of {update}'s keywords: "not passed", told apart from an explicit value.
      UNSET = Object.new.freeze
      private_constant :UNSET

      include Query

      # The text of the gateway's +details_v1+ attestation, which +confirm_details: true+
      # stands for on {create} and on an {update} that changes +min_amount+ or +no_minimum+. Show it to the
      # merchant and send +confirm_details: true+ only once they have accepted it.
      CONFIRM_DETAILS_TEXT =
        "I have checked the address, network, token and minimum deposit on the venue's deposit " \
        "page and confirm they are correct. Funds sent to a wrong address or network, or below " \
        "the venue's minimum, may be permanently lost and cannot be recovered by rail0."

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
      # @param include_deleted [Boolean, nil] +true+ lists deleted destinations too
      #   (+deleted_at+ set); left out by default.
      # @return [Hash] { data: Array<Hash>, meta: { page:, per_page:, total:, total_pages:, links: } }
      def list(wallet_id: nil, status: nil, sort: nil, page: nil, per_page: nil, include_deleted: nil)
        query = build_query(wallet_id: wallet_id, status: status, sort: sort, page: page, per_page: per_page,
                            include_deleted: include_deleted)
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
      # The venue's minimum deposit is REQUIRED too, as EXACTLY ONE of: +min_amount+, the
      # figure the merchant read on the venue's deposit page, or +no_minimum: true+, the
      # merchant's statement that the venue has none. Neither, a blank figure, or both raise
      # ArgumentError here and nothing is sent (the gateway would answer 422
      # +minimum_required+ / +minimum_conflict+). Nothing is defaulted: a minimum nobody
      # looked up is how a deposit gets lost, so pass what the merchant answered.
      #
      # +label+ is REQUIRED: the name the merchant knows the destination by. The gateway
      # trims it; it must be unique among the account's live destinations, compared without
      # regard to case (409 +payout_destination_label_taken+ otherwise; deleting a destination
      # frees its label). A blank or whitespace-only label raises ArgumentError here and
      # nothing is sent (the gateway would answer 422 +label_required+).
      #
      # @param wallet_id [String] The wallet (uuid or address) that will sign transfers to it;
      #   must be the session's own.
      # @param chain_id [Integer] The chain the deposit address was issued for.
      # @param token [String] The token's address on that chain.
      # @param address [String] The deposit address, generated at the venue WITH THE NETWORK
      #   SET TO THIS CHAIN.
      # @param label [String] The destination's name, unique per account (case-insensitive).
      # @param confirm_details [Boolean] The merchant's acceptance of {CONFIRM_DETAILS_TEXT}.
      # @param min_amount [String, nil] The venue's deposit minimum in base units. A payout
      #   below it is refused (+payout_below_minimum+) and the proof is raised to it.
      # @param no_minimum [Boolean] +true+: the merchant states the venue has no minimum.
      # @return [Hash] The destination.
      # @raise [ArgumentError] when +label+ is blank, when neither or both of +min_amount+ /
      #   +no_minimum: true+ are given, or +min_amount+ is blank.
      def create(wallet_id:, chain_id:, token:, address:, label:, confirm_details:, min_amount: nil,
                 no_minimum: false)
        check_label!(label)
        figure = !min_amount.nil? && !min_amount.to_s.strip.empty?
        if figure == (no_minimum == true)
          raise ArgumentError, "exactly one of min_amount (the venue's minimum, base units) or no_minimum: true " \
                               "is required"
        end

        body = { wallet_id: wallet_id, chain_id: chain_id, token: token, address: address,
                 confirm_details: confirm_details, label: label, min_amount: min_amount,
                 no_minimum: (true if no_minimum == true) }.compact
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
      # - +label+: renames it. Never blank (ArgumentError here, 422 +label_required+ at the
      #   gateway) and unique among the account's live destinations, case-insensitive (409
      #   +payout_destination_label_taken+).
      # - +min_amount+: the venue's minimum, base units (+"0"+ is a figure like any other); it
      #   also clears +no_minimum+. Never blank: an empty string raises ArgumentError here.
      # - +no_minimum: true+: the venue has no minimum — how a minimum is removed (+min_amount+
      #   becomes nil). Never together with +min_amount+ (ArgumentError here, 422
      #   +minimum_conflict+ at the gateway).
      # - A request that CHANGES +min_amount+ or +no_minimum+ also needs +confirm_details: true+ — the same
      #   attestation as {create} ({CONFIRM_DETAILS_TEXT}), else 422 +confirmation_required+
      #   and nothing is written. Raising the minimum above the destination's latest proof
      #   takes its verification away: prove it again with a new proof.
      # - +active: false+ disables it (any wallet of the account may); its unsigned pending
      #   payout is cancelled, a signed one refuses the switch-off 409 +payout_already_signed+.
      #   +active: true+ re-enables it with the verification it had.
      #
      # @param id [String] Destination uuid.
      # @return [Hash] The destination.
      def update(id, label: UNSET, min_amount: UNSET, no_minimum: UNSET, active: UNSET, confirm_details: UNSET)
        body = { label: label, min_amount: min_amount, no_minimum: no_minimum, active: active,
                 confirm_details: confirm_details }.reject { |_, v| v.equal?(UNSET) }
        if body.except(:confirm_details).empty?
          raise ArgumentError, "at least one of label, min_amount, no_minimum or active is required"
        end

        check_label!(body[:label]) if body.key?(:label)
        check_minimum!(body)

        http.patch("/payout_destinations/#{segment(id)}", body)
      end

      # Delete a destination (soft): it leaves the lists ({list} shows it again with
      # +include_deleted: true+), and its payment method and its label are free to be
      # registered again. The row is
      # kept — its payouts and audit trail still name it, and {get} / {events} still read it
      # with +deleted_at+ set and +status+ "disabled". Its pending payout is settled first, as
      # on a switch-off: an unsigned one is cancelled, a signed one refuses the delete 409
      # +payout_already_signed+. Only the destination's own wallet may delete it; a deleted
      # destination takes no further write (404). Recorded as +destination.deleted+.
      # @param id [String] Destination uuid.
      # @return [Hash] The destination as it now stands.
      def delete(id)
        http.delete("/payout_destinations/#{segment(id)}")
      end

      # What a payout to the destination would keep back in the wallet right now, computed
      # from the wallet's payments and the chain's current fees (nothing is stored):
      #
      # - +refund_reserve+: the refundable balance of the wallet's payments in this token
      #   still inside their refund window (+refundable_payments+ of them).
      # - +gas_reserve+: on a chain whose gas IS this token (+native_gas+, Arc's USDC), the gas
      #   for those refunds and for capturing the open authorizations plus +base_captures+
      #   more; "0" elsewhere.
      # - +gas_allowance+: the payout transfer's own fee, always kept back on a native-gas chain.
      # - +available+: what +amount: "all"+ moves with both reserves kept (the default).
      #
      # Every amount is base units with its +*_formatted+ twin. Both reserves can be opted
      # out of per payout ({Payouts#prepare}'s +keep_refund_reserve:+ / +keep_gas_reserve:+).
      # Any wallet of the account may read it; a deleted destination still reads.
      # @param id [String] Destination uuid.
      # @return [Hash] The reserves (see Rail0::Types::PayoutReserves).
      def reserves(id)
        http.get("/payout_destinations/#{segment(id)}/reserves")
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

      private

      # A destination's label is required and never blank (the gateway's +label_required+);
      # refused here so nothing is sent.
      def check_label!(label)
        return unless label.to_s.strip.empty?

        raise ArgumentError, "label is required and cannot be blank: name the destination"
      end

      # {update}'s local minimum checks, before anything is sent: a blank +min_amount+ is
      # never a minimum (the gateway's +minimum_required+; +no_minimum: true+ removes one),
      # and a figure beside +no_minimum: true+ contradicts itself (+minimum_conflict+).
      def check_minimum!(body)
        if body.key?(:min_amount) && body[:min_amount].to_s.strip.empty?
          raise ArgumentError, "min_amount cannot be blank: pass the venue's minimum, or no_minimum: true to remove it"
        end
        return unless body.key?(:min_amount) && body[:no_minimum] == true

        raise ArgumentError, "pass min_amount or no_minimum: true, not both"
      end
    end
  end
end
