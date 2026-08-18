# frozen_string_literal: true

require "net/http"
require "json"
require "uri"
require "forwardable"
require_relative "api_error"
require_relative "backoff"
require_relative "default_logger"

module Rail0
  # @!visibility private
  # Executes one logical call against the gateway: builds the URL, retries on
  # network errors per the client's max_retries/retry_delay, translates non-2xx
  # responses into Rail0::ApiError, parses the body (including the paginated
  # {data, meta} envelope), and logs every attempt. One instance per call.
  class Request
    extend Forwardable

    ERRORS = [
      SocketError, Errno::ECONNREFUSED, Errno::ETIMEDOUT,
      Net::OpenTimeout, Net::ReadTimeout, OpenSSL::SSL::SSLError
    ].freeze

    TYPES = { get: Net::HTTP::Get, post: Net::HTTP::Post,
              put: Net::HTTP::Put, patch: Net::HTTP::Patch,
              delete: Net::HTTP::Delete }.freeze

    def_delegators :client, :base_url, :headers, :timeout, :logger, :max_retries, :retry_delay,
                   :retry_on_429, :retry_after_cap

    attr_reader :client, :method, :path, :body, :paginated, :extra_headers

    def initialize(client:, method:, path:, body:, paginated:, extra_headers:)
      @client        = client
      @method        = method
      @path          = path
      @body          = body
      @paginated     = paginated
      @extra_headers = extra_headers
      freeze
    end

    def call
      url = "#{base_url}#{path}"
      response, duration_ms, attempt = with_retries(url) { perform(url) }

      unless response.is_a?(Net::HTTPSuccess)
        error_body = parse_error_body(response)
        api_error  = ApiError.new(response.code.to_i, error_code(error_body),
                                  error_message(error_body, response), title: error_body[:title],
                                  retry_after: retry_after_seconds(response))
        logger.call(LogEntry.new(
          method: method.to_s.upcase, url: url, duration_ms: duration_ms, attempt: attempt,
          request_body: body, status: response.code.to_i, response_body: error_body, error: api_error
        ))
        raise api_error
      end

      body_data = parse_body(response)
      result    = paginated ? { data: body_data, meta: page_meta(response) } : body_data
      logger.call(LogEntry.new(
        method: method.to_s.upcase, url: url, duration_ms: duration_ms, attempt: attempt,
        request_body: body, status: response.code.to_i, response_body: result
      ))
      result
    end

    private

    # One loop for the two things worth retrying, which fail in different ways: a network
    # error raises, a rate limit comes back as a perfectly good 429 response.
    #
    # A 429 is the one status this SDK retries, and the reason is not that it is common.
    # The gateway rejects it in middleware (Rack::Attack), BEFORE the request reaches the
    # application — so nothing was executed, and retrying carries no risk of doing the
    # work twice. That is not true of a 502 or a timeout on, say, a capture, where the
    # broadcast may already be in flight. Which is why the method does not matter here and
    # a POST is retried like a GET.
    #
    # The sleep is on the CALLING thread. There is no thread pool in this SDK and no
    # promise to wait on: a job that turns retry_on_429 on is choosing to block.
    def with_retries(url)
      attempt = 1
      loop do
        start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        begin
          response = yield
        rescue *ERRORS => e
          will_retry = attempt <= max_retries
          logger.call(LogEntry.new(
            method: method.to_s.upcase, url: url, duration_ms: elapsed_ms(start),
            attempt: attempt, request_body: body, error: e, will_retry: will_retry
          ))
          raise unless will_retry

          attempt += 1
          sleep(retry_delay * (2**(attempt - 2)))
          next
        end

        return [response, elapsed_ms(start), attempt] unless retry_throttled?(response, attempt)

        delay = Backoff.throttle_delay(
          retry_after: response["retry-after"], attempt: attempt,
          base: retry_delay, cap: retry_after_cap
        )
        logger.call(LogEntry.new(
          method: method.to_s.upcase, url: url, duration_ms: elapsed_ms(start), attempt: attempt,
          request_body: body, status: response.code.to_i,
          response_body: parse_error_body(response), will_retry: true
        ))
        attempt += 1
        sleep(delay)
      end
    end

    # Whether this response is a rate limit the client opted into retrying, and whether
    # there is budget left.
    #
    # `max_retries` is what bounds it, except that its default is 0 — so requiring both
    # flags would make retry_on_429 a silent no-op. One retry is the floor when the
    # caller asked for the behaviour at all.
    def retry_throttled?(response, attempt)
      return false unless retry_on_429 && response.code.to_i == 429

      attempt <= [max_retries, 1].max
    end

    # @return [Integer, nil] the Retry-After header as whole seconds, when it is a
    #   positive number. HTTP-date form is not parsed: the gateway never sends one, and
    #   guessing at a date would be worse than admitting we have no instruction.
    def retry_after_seconds(response)
      seconds = Backoff.positive_number(response["retry-after"])
      seconds&.round
    end

    def parse_body(response)
      raw = response.body
      return nil if raw.nil? || raw.strip.empty?
      JSON.parse(raw, symbolize_names: true)
    end

    def page_meta(response)
      {
        page:     response["x-page"].to_i,
        per_page: response["x-per-page"].to_i,
        total:    response["x-total-count"].to_i
      }.freeze
    end

    def perform(url)
      uri  = URI.parse(url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl       = uri.scheme == "https"
      http.open_timeout  = timeout
      http.read_timeout  = timeout
      http.write_timeout = timeout

      req_class = TYPES.fetch(method, Net::HTTP::Post)
      req = req_class.new(uri.request_uri)
      headers.merge(extra_headers).each { |k, v| req[k] = v }
      req.body = body.to_json if body && %i[post put patch].include?(method)

      http.request(req)
    end

    def parse_error_body(response)
      JSON.parse(response.body, symbolize_names: true)
    rescue JSON::ParserError, TypeError
      {}
    end

    def error_code(body)
      body[:code] || body[:error] || body[:status]
    end

    def error_message(body, response = nil)
      body[:detail] || body[:message] || body[:error] || (response && "HTTP #{response.code}")
    end

    def elapsed_ms(start)
      (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000
    end
  end
end
