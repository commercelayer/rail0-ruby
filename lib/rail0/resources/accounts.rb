# frozen_string_literal: true

module Rail0
  module Resources
    # The merchant account itself (requires JWT).
    #
    # One method, and that is the whole surface by design: the gateway guards
    # `/accounts/:account_id` with an ownership check — a JWT whose account matches the
    # path — so a caller can only ever read its OWN account. There is no endpoint for
    # reading another merchant's, and an id that is not an account answers 404 exactly as
    # another account's id does, so the pair cannot be used to learn whether an account
    # exists.
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
    end
  end
end
