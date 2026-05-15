require_relative "http_client"
require_relative "resources/payments"
require_relative "resources/tokens"
require_relative "resources/utils"

module Rail0
  # Entry point for the RAIL0 SDK.
  #
  #   client = Rail0::Client.new(base_url: "https://api.rail0.xyz")
  #   state  = client.payments.get(payment_id)
  class Client
    # @return [Resources::Payments] Payment lifecycle operations.
    attr_reader :payments

    # @return [Resources::Tokens] Token allowlist queries.
    attr_reader :tokens

    # @return [Resources::Utils] Contract introspection: domain separator, version.
    attr_reader :utils

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
      @payments = Resources::Payments.new(http)
      @tokens   = Resources::Tokens.new(http)
      @utils    = Resources::Utils.new(http)
    end
  end
end
