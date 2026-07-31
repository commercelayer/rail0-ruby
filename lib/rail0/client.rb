# frozen_string_literal: true

require "http_client"
require "resources/auth"
require "resources/chains"
require "resources/tokens"
require "resources/health"
require "resources/payment_methods"
require "resources/wallets"
require "resources/payments"
require "resources/disputes"
require "resources/webhooks"
require "resources/analytics"

module Rail0
  # Entry point for the RAIL0 SDK.
  #
  #   client = Rail0::Client.new(base_url: "https://api.rail0.xyz")
  #   resp   = client.auth.login(private_key: "0x...", domain: "api.rail0.xyz")
  #   resp   = client.payments.create(chain_id: 84532, mode: "authorize", amount: "100000000", token: "0x...", payer: "0x...", payee: "0x...")
  #
  # JWT-protected resources (wallets, webhooks, payments.list) expect the token to
  # be supplied via +headers+: pass +{ "Authorization" => "Bearer <jwt>" }+ (the
  # JWT is obtained from +auth.login+). The SDK does not persist the token for you.
  class Client
    # @!attribute [r] auth
    #   @return [Resources::Auth] SIWE authentication operations.
    # @!attribute [r] chains
    #   @return [Resources::Chains] Public blockchain catalog.
    # @!attribute [r] tokens
    #   @return [Resources::Tokens] Public token catalog.
    # @!attribute [r] health
    #   @return [Resources::Health] Gateway liveness/readiness check.
    # @!attribute [r] payment_methods
    #   @return [Resources::PaymentMethods] Public buyer-facing payment-method discovery.
    # @!attribute [r] wallets
    #   @return [Resources::Wallets] Account-scoped wallet management (JWT).
    # @!attribute [r] payments
    #   @return [Resources::Payments] Payment lifecycle operations.
    # @!attribute [r] disputes
    #   @return [Resources::Disputes] Account-level dispute list (JWT).
    # @!attribute [r] webhooks
    #   @return [Resources::Webhooks] Webhook subscription management (JWT).
    # @!attribute [r] analytics
    #   @return [Resources::Analytics] Account-scoped payment analytics (JWT).
    attr_reader :auth, :chains, :tokens, :health, :payment_methods,
                :wallets, :payments, :disputes, :webhooks, :analytics


    # @param base_url [String] Base URL of the RAIL0 API, e.g. "https://api.rail0.xyz".
    # @param headers [Hash] Default headers merged into every request (e.g. Authorization).
    # @param timeout [Numeric] Timeout in seconds. Default: 30.
    # @param logger [#call, nil] Optional logger. Pass Rail0::DEFAULT_LOGGER for built-in output.
    # @param max_retries [Integer] Extra attempts after a network failure. Default: 0.
    # @param retry_delay [Numeric] Base delay in seconds between retries (exponential backoff). Default: 0.2.
    def initialize(base_url:, headers: {}, timeout: 30, logger: nil, max_retries: 0, retry_delay: 0.2)
      http = HttpClient.new(
        base_url: base_url, headers: headers, timeout: timeout,
        logger: logger, max_retries: max_retries, retry_delay: retry_delay
      )
      @auth            = Resources::Auth.new(http)
      @chains          = Resources::Chains.new(http)
      @tokens          = Resources::Tokens.new(http)
      @health          = Resources::Health.new(http)
      @payment_methods = Resources::PaymentMethods.new(http)
      @wallets         = Resources::Wallets.new(http)
      @payments        = Resources::Payments.new(http)
      @disputes        = Resources::Disputes.new(http)
      @webhooks        = Resources::Webhooks.new(http)
      @analytics       = Resources::Analytics.new(http)
      freeze
    end
  end
end
