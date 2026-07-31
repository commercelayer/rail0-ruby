# frozen_string_literal: true

require_relative "default_logger"
require_relative "request"

module Rail0
  # @!visibility private
  class HttpClient
    attr_reader :base_url, :headers, :timeout, :logger, :max_retries, :retry_delay

    def initialize(base_url:, headers: {}, timeout: 30, logger: nil, max_retries: 0, retry_delay: 0.2)
      @base_url    = base_url.chomp("/")
      @headers     = { "Content-Type" => "application/json" }.merge(headers)
      @timeout     = timeout
      @logger      = logger || NULL_LOGGER
      @max_retries = max_retries
      @retry_delay = retry_delay
      freeze
    end

    def get(path)
      request(:get, path)
    end

    # GET a paginated collection endpoint. The gateway returns a bare JSON array
    # with pagination carried in the X-Total-Count / X-Page / X-Per-Page response
    # headers (not a {data, meta} envelope), so this reads the meta back from the
    # headers and wraps the array. Non-paginated array endpoints (blockchains,
    # tokens, payment_methods) use plain #get instead.
    # @return [Hash] { data: Array<Hash>, meta: { page:, per_page:, total: } }
    def get_list(path)
      request(:get, path, nil, paginated: true)
    end

    # @param headers [Hash] extra headers merged over the client defaults for this
    #   request only (e.g. { "Idempotency-Key" => "..." }).
    def post(path, body = nil, headers: {})
      request(:post, path, body, headers: headers)
    end

    def put(path, body = nil)
      request(:put, path, body)
    end

    def patch(path, body = nil)
      request(:patch, path, body)
    end

    def delete(path)
      request(:delete, path)
    end

    private

    def request(method, path, body = nil, paginated: false, headers: {})
      Request.new(
        client: self, method: method, path: path, body: body,
        paginated: paginated, extra_headers: headers
      ).call
    end
  end
end
