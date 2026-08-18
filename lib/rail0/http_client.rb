# frozen_string_literal: true

require_relative "default_logger"
require_relative "request"

module Rail0
  # @!visibility private
  class HttpClient
    attr_reader :base_url, :timeout, :logger, :max_retries, :retry_delay,
                :retry_on_429, :retry_after_cap

    # @param retry_on_429 [Boolean] retry a rate-limited request, waiting the gateway's
    #   Retry-After (see Rail0::Backoff). OFF by default, deliberately: an automatic
    #   sleep hides back-pressure from the one process that could react to it, and in a
    #   request/response app it turns a 429 into a stalled page. Turn it on for a job.
    #
    #   It does NOT need `max_retries` to be set as well. That pairing is a footgun —
    #   the flag would silently do nothing — so on its own it allows one retry.
    # @param retry_after_cap [Numeric] longest wait to honour, in seconds. The gateway
    #   sends its whole throttle period as Retry-After rather than the time left in it,
    #   so this bounds both the over-wait and any hostile value from in between.
    def initialize(base_url:, headers: {}, token: nil, timeout: 30, logger: nil,
                   max_retries: 0, retry_delay: 0.2, retry_on_429: false,
                   retry_after_cap: 60)
      @base_url        = base_url.chomp("/")
      @static_headers  = { "Content-Type" => "application/json" }.merge(headers)
      @token           = token
      @timeout         = timeout
      @logger          = logger || NULL_LOGGER
      @max_retries     = max_retries
      @retry_delay     = retry_delay
      @retry_on_429    = retry_on_429
      @retry_after_cap = retry_after_cap
      freeze
    end

    # Headers for one request.
    #
    # A `token` is resolved HERE, per request, rather than baked in at construction:
    # you need a client to call auth.login, and the login's JWT to build the client
    # you actually use, so a header fixed at construction forced a whole new client
    # (and its ten resource objects) on every sign-in and every refresh. Passing a
    # callable — `token: -> { current_jwt }` — keeps one shared client valid across
    # token rotations, which is what a long-lived process needs. A String token is
    # accepted for the simple case, and an explicit Authorization in `headers`
    # still wins so nothing existing changes. (#11)
    #
    # The object stays frozen: what varies is the proc's answer, not this object.
    def headers
      return @static_headers if @token.nil? || @static_headers.key?("Authorization")

      resolved = @token.respond_to?(:call) ? @token.call : @token
      return @static_headers if resolved.nil? || resolved.to_s.empty?

      @static_headers.merge("Authorization" => "Bearer #{resolved}")
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
