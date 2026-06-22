require_relative "http_client"
require_relative "resources/accounts"
require_relative "resources/auth"
require_relative "resources/chains"
require_relative "resources/payments"
require_relative "resources/tokens"
require_relative "resources/wallets"

module Rail0
  # Entry point for the RAIL0 SDK.
  #
  #   client = Rail0::Client.new(base_url: "https://api.rail0.xyz")
  #   resp   = client.auth.login(private_key: "0x...", domain: "api.rail0.xyz")
  #   resp   = client.payments.create(chain_id: 84532, mode: "authorize", amount: "100000000", token: "0x...", payer: "0x...", payee: "0x...")
  class Client
    # @return [Resources::Auth] SIWE authentication operations.
    attr_reader :auth
    # @return [Resources::Accounts] Account configuration operations.
    attr_reader :accounts
    # @return [Resources::Chains] Blockchain listing operations.
    attr_reader :chains
    # @return [Resources::Payments] Payment lifecycle operations.
    attr_reader :payments
    # @return [Resources::Tokens] Token listing operations.
    attr_reader :tokens
    # @return [Resources::Wallets] Wallet token operations.
    attr_reader :wallets

    # @param base_url [String] Base URL of the RAIL0 API, e.g. "https://api.rail0.xyz".
    # @param headers [Hash] Default headers merged into every request.
    # @param timeout [Numeric] Timeout in seconds. Default: 30.
    # @param logger [#call, nil] Optional logger. Pass Rail0::DEBUG_LOGGER for built-in output.
    # @param max_retries [Integer] Extra attempts after a network failure. Default: 0.
    # @param retry_delay [Numeric] Base delay in seconds between retries (exponential backoff). Default: 0.2.
    def initialize(base_url:, headers: {}, timeout: 30, logger: nil, max_retries: 0, retry_delay: 0.2)
      http      = HttpClient.new(
        base_url: base_url, headers: headers, timeout: timeout,
        logger: logger, max_retries: max_retries, retry_delay: retry_delay
      )
      @auth     = Resources::Auth.new(http)
      @accounts = Resources::Accounts.new(http)
      @chains   = Resources::Chains.new(http)
      @payments = Resources::Payments.new(http)
      @tokens   = Resources::Tokens.new(http)
      @wallets  = Resources::Wallets.new(http)
    end
  end
end
