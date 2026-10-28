# frozen_string_literal: true

require_relative "query"

module Rail0
  module Resources
    # The merchant account itself (requires JWT).
    #
    # Read and update. The gateway guards `/accounts/:account_id` with an
    # owner-or-operator check: a merchant session reaches only its OWN account, and an
    # operator (an admin session) may reach any. For anyone else another account's id
    # answers the same 403 `not_your_account` as a plain ownership miss, so the pair
    # cannot be used to learn whether an account exists.
    #
    # The gateway's PATCH also takes `active`, but that field is the OPERATOR's (an owner
    # sending it gets 403), so it is deliberately not exposed here.
    #
    # The account's wallets are a collection under the same path and live on
    # {Resources::Wallets}; buyer-facing discovery of what a merchant accepts lives on
    # {Resources::PaymentMethods}.
    class Accounts
      include Query

      attr_reader :http

      def initialize(http)
        @http = http
        freeze
      end

      # The account's own profile.
      # @param account_id [String] The account UUID — must be the one this JWT belongs to.
      # @return [Hash] `id`, `name`, `email`, `priority_tip`, `authorization_ttl`, `refund_ttl`,
      #   `payment_windows`, `created_at`, `updated_at`.
      #   `email` is part of the response because only the account's owner, or an operator,
      #   can read it. `priority_tip` is the fee setting of the account's OWN transactions
      #   (authorize, capture, void, release, refund): true, the default, tips the network's
      #   suggested priority fee; false uses the chain's minimum tip — 0 on most chains,
      #   25 gwei on Polygon PoS/Amoy. The buyer's dispute/close_dispute never read it.
      #   `authorization_ttl` / `refund_ttl` are the payment windows the account's NEW
      #   payments are created with, in seconds — its own or the gateway default;
      #   `payment_windows` says which, and the bounds a new value must fit.
      def get(account_id)
        http.get("/accounts/#{segment(account_id)}")
      end

      # Update the account's own profile (PATCH /accounts/:account_id).
      #
      # Only the fields passed are sent, and at least one is required: a PATCH with
      # nothing to change is a caller bug, which the gateway answers with 400 — so this
      # raises ArgumentError first rather than spending a request on it. Name and email
      # are UNIQUE across accounts, so a value another account already holds answers 409.
      # `priority_tip: false` is a value, not an absence: it is sent as false and switches
      # the account's own transactions to the chain's minimum tip; nil leaves it alone.
      # The payment windows take a number of seconds, or `:default` to put one back on the
      # gateway default (sent as null); nil leaves it alone. Outside the bounds in
      # `payment_windows`, or closer than its `min_refund_window`, the gateway answers 422
      # invalid_payment_windows. A change moves only the payments created afterwards.
      #
      # This is a write on the account itself, so a deactivated wallet (403
      # wallet_deactivated) or a deactivated account (403 account_deactivated) cannot
      # make it: a revoked key must not be able to redirect the contact address where
      # the merchant's operational notifications go.
      #
      # @param account_id [String] The account UUID — must be the one this JWT belongs to.
      # @param name [String, nil] New display name (non-blank; unique across accounts).
      # @param email [String, nil] New contact email (non-blank; unique across accounts).
      # @param priority_tip [Boolean, nil] Tip the network's suggested priority fee on the
      #   account's own transactions (true, the gateway default) or the chain's minimum tip
      #   (false). Owner or admin.
      # @param authorization_ttl [Integer, :default, nil] Authorization (capture) window of
      #   new payments, in seconds, or :default. Owner or admin.
      # @param refund_ttl [Integer, :default, nil] Refund and dispute window of new
      #   payments, in seconds, or :default. Owner or admin.
      # @return [Hash] the updated profile, same shape as {get}.
      # @raise [ArgumentError] when no field is given, or a window is neither an Integer
      #   nor :default.
      def update(account_id, name: nil, email: nil, priority_tip: nil, authorization_ttl: nil, refund_ttl: nil)
        body = {}
        body[:name]         = name         unless name.nil?
        body[:email]        = email        unless email.nil?
        body[:priority_tip] = priority_tip unless priority_tip.nil?
        { authorization_ttl: authorization_ttl, refund_ttl: refund_ttl }.each do |key, value|
          body[key] = window(key, value) unless value.nil?
        end
        raise ArgumentError, "at least one of name, email, priority_tip or a payment window is required" if body.empty?

        http.patch("/accounts/#{segment(account_id)}", body)
      end

      private

      # A payment window as the gateway takes it: whole seconds, or null for the default.
      def window(key, value)
        return if value == :default
        return value if value.is_a?(Integer)

        raise ArgumentError, "#{key} must be an Integer number of seconds or :default"
      end
    end
  end
end
