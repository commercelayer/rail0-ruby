require_relative "http_client"
require_relative "resources/merchants"
require_relative "resources/payments"

module Rail0
  # Entry point for the RAIL0 SDK.
  #
  #   client = Rail0::Client.new(base_url: "https://api.rail0.xyz")
  #   resp   = client.payments.create_payment(payment: config, amount: "50000000", chain_id: 84532, mode: "authorize")
  class Client
    # @return [Resources::Merchants] Merchant configuration operations.
    attr_reader :merchants
    # @return [Resources::Payments] Payment lifecycle operations.
    attr_reader :payments

    # @param base_url [String] Base URL of the RAIL0 API, e.g. "https://api.rail0.xyz".
    # @param headers [Hash] Default headers merged into every request.
    # @param timeout [Numeric] Timeout in seconds. Default: 30.
    # @param logger [#call, nil] Optional logger. Pass Rail0::DEBUG_LOGGER for built-in output.
    # @param max_retries [Integer] Extra attempts after a network failure. Default: 0.
    # @param retry_delay [Numeric] Base delay in seconds between retries (exponential backoff). Default: 0.2.
    def initialize(base_url:, headers: {}, timeout: 30, logger: nil, max_retries: 0, retry_delay: 0.2)
      http       = HttpClient.new(
        base_url: base_url, headers: headers, timeout: timeout,
        logger: logger, max_retries: max_retries, retry_delay: retry_delay
      )
      @merchants = Resources::Merchants.new(http)
      @payments  = Resources::Payments.new(http)
    end
  end
end
