require_relative "http_client"
require_relative "resources/auth"
require_relative "resources/chains"
require_relative "resources/tokens"
require_relative "resources/health"
require_relative "resources/payment_methods"
require_relative "resources/wallets"
require_relative "resources/payments"
require_relative "resources/disputes"
require_relative "resources/webhooks"

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
    # @return [Resources::Auth] SIWE authentication operations.
    attr_reader :auth
    # @return [Resources::Chains] Public blockchain catalog.
    attr_reader :chains
    # @return [Resources::Tokens] Public token catalog.
    attr_reader :tokens
    # @return [Resources::Health] Gateway liveness/readiness check.
    attr_reader :health
    # @return [Resources::PaymentMethods] Public buyer-facing payment-method discovery.
    attr_reader :payment_methods
    # @return [Resources::Wallets] Account-scoped wallet management (JWT).
    attr_reader :wallets
    # @return [Resources::Payments] Payment lifecycle operations.
    attr_reader :payments
    # @return [Resources::Disputes] Account-level dispute list (JWT).
    attr_reader :disputes
    # @return [Resources::Webhooks] Webhook subscription management (JWT).
    attr_reader :webhooks

    # @param base_url [String] Base URL of the RAIL0 API, e.g. "https://api.rail0.xyz".
    # @param headers [Hash] Default headers merged into every request (e.g. Authorization).
    # @param timeout [Numeric] Timeout in seconds. Default: 30.
    # @param logger [#call, nil] Optional logger. Pass Rail0::DEBUG_LOGGER for built-in output.
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
    end
  end
end
