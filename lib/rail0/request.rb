# frozen_string_literal: true

require "net/http"
require "json"
require "uri"
require "forwardable"
require "api_error"
require "default_logger"

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

    def_delegators :client, :base_url, :headers, :timeout, :logger, :max_retries, :retry_delay

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
        api_error  = ApiError.new(response.code.to_i, error_code(error_body), error_message(error_body, response))
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

    def with_retries(url)
      attempt = 1
      start  = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = yield
      [result, elapsed_ms(start), attempt]
    rescue *ERRORS => e
      will_retry = attempt <= max_retries
      logger.call(LogEntry.new(
        method: method.to_s.upcase, url: url, duration_ms: elapsed_ms(start), attempt: attempt,
        request_body: body, error: e, will_retry: will_retry
      ))
      raise unless will_retry
      attempt += 1
      sleep(retry_delay * (2**(attempt - 2)))
      retry
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
      body[:status] || body[:code] || body[:error]
    end

    def error_message(body, response = nil)
      body[:message] || body[:error] || (response && "HTTP #{response.code}")
    end

    def elapsed_ms(start)
      (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000
    end
  end
end
