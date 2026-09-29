# frozen_string_literal: true

module Rail0
  module Resources
    # The merchant account itself (requires JWT).
    #
    # Read and update, both on the caller's OWN account: the gateway guards
    # `/accounts/:account_id` with an ownership check — a JWT whose account matches the
    # path — so a caller can only ever reach its own. There is no endpoint for reading or
    # changing another merchant's, and an id that is not an account answers 404 exactly
    # as another account's id does, so the pair cannot be used to learn whether an
    # account exists.
    #
    # The gateway's PATCH also takes `active`, but that field is the OPERATOR's (an owner
    # sending it gets 403), so it is deliberately not exposed here.
    #
    # The account's wallets are a collection under the same path and live on
    # {Resources::Wallets}; buyer-facing discovery of what a merchant accepts lives on
    # {Resources::PaymentMethods}.
    class Accounts
      attr_reader :http

      def initialize(http)
        @http = http
        freeze
      end

      # The account's own profile.
      # @param account_id [String] The account UUID — must be the one this JWT belongs to.
      # @return [Hash] `id`, `name`, `email`, `created_at`, `updated_at`. `email` is part of
      #   the response because the holder is this endpoint's only possible caller: it is a
      #   merchant reading its own contact address, never another's.
      def get(account_id)
        http.get("/accounts/#{account_id}")
      end

      # Update the account's own profile (PATCH /accounts/:account_id).
      #
      # Only the fields passed are sent, and at least one is required: a PATCH with
      # nothing to change is a caller bug, which the gateway answers with 400 — so this
      # raises ArgumentError first rather than spending a request on it. Both fields are
      # UNIQUE across accounts, so a value another account already holds answers 409.
      #
      # This is a write on the account itself, so a deactivated wallet (403
      # wallet_deactivated) or a deactivated account (403 account_deactivated) cannot
      # make it: a revoked key must not be able to redirect the contact address where
      # the merchant's operational notifications go.
      #
      # @param account_id [String] The account UUID — must be the one this JWT belongs to.
      # @param name [String, nil] New display name (non-blank; unique across accounts).
      # @param email [String, nil] New contact email (non-blank; unique across accounts).
      # @return [Hash] the updated profile, same shape as {get}.
      # @raise [ArgumentError] when neither name nor email is given.
      def update(account_id, name: nil, email: nil)
        body = {}
        body[:name]  = name  unless name.nil?
        body[:email] = email unless email.nil?
        raise ArgumentError, "at least one of name or email is required" if body.empty?

        http.patch("/accounts/#{account_id}", body)
      end
    end
  end
end
