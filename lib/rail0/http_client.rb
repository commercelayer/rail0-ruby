require "net/http"
require "json"
require "uri"

module Rail0
  # One log record emitted per request attempt.
  LogEntry = Struct.new(
    :method, :url, :duration_ms, :request_body,
    :status, :response_body, :error, :attempt, :will_retry,
    keyword_init: true
  )

  # Built-in logger that writes a one-line summary to $stdout.
  #
  #   client = Rail0::Client.new(base_url: "https://api.rail0.xyz", logger: Rail0::DEBUG_LOGGER)
  DEBUG_LOGGER = lambda do |entry|
    flag        = entry.error ? " ERROR" : ""
    status_part = entry.status ? " #{entry.status}" : ""
    attempt_part =
      if entry.attempt
        retry_part = entry.will_retry ? ", retrying" : ""
        " [attempt #{entry.attempt}#{retry_part}]"
      else
        ""
      end

    parts = ["[rail0]#{flag}#{attempt_part} #{entry.method}#{status_part} #{entry.url} #{entry.duration_ms.round}ms"]
    parts << "-> #{entry.request_body.inspect}" if entry.request_body
    parts << "<- #{entry.response_body.inspect}" if entry.response_body
    parts << "! #{entry.error}"                  if entry.error
    $stdout.puts parts.join(" ")
  end

  # @!visibility private
  class HttpClient
    def initialize(base_url:, headers: {}, timeout: 30, logger: nil, max_retries: 0, retry_delay: 0.2)
      @base_url    = base_url.chomp("/")
      @headers     = { "Content-Type" => "application/json" }.merge(headers)
      @timeout     = timeout
      @logger      = logger
      @max_retries = max_retries
      @retry_delay = retry_delay
    end

    def get(path)
      request(:get, path)
    end

    def post(path, body = nil)
      request(:post, path, body)
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

    def request(method, path, body = nil)
      url          = "#{@base_url}#{path}"
      max_attempts = @max_retries + 1
      track        = @max_retries > 0

      (1..max_attempts).each do |attempt|
        sleep(@retry_delay * (2**(attempt - 2))) if attempt > 1

        start = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        begin
          response = do_request(method, url, body)
        rescue SocketError, Errno::ECONNREFUSED, Errno::ETIMEDOUT,
               Net::OpenTimeout, Net::ReadTimeout, OpenSSL::SSL::SSLError => e
          duration_ms = elapsed_ms(start)
          will_retry  = attempt < max_attempts
          log(LogEntry.new(
            method: method.to_s.upcase, url: url, duration_ms: duration_ms,
            request_body: body, error: e,
            **(track ? { attempt: attempt, will_retry: will_retry } : {})
          ))
          next if will_retry
          raise
        end

        duration_ms = elapsed_ms(start)

        unless response.is_a?(Net::HTTPSuccess)
          error_body  = parse_error_body(response)
          api_error   = ApiError.new(response.code.to_i, error_body[:error], error_body[:message])
          log(LogEntry.new(
            method: method.to_s.upcase, url: url, duration_ms: duration_ms,
            request_body: body, status: response.code.to_i,
            response_body: error_body, error: api_error,
            **(track ? { attempt: attempt } : {})
          ))
          raise api_error
        end

        data = JSON.parse(response.body, symbolize_names: true)
        log(LogEntry.new(
          method: method.to_s.upcase, url: url, duration_ms: duration_ms,
          request_body: body, status: response.code.to_i, response_body: data,
          **(track ? { attempt: attempt } : {})
        ))
        return data
      end
    end

    def do_request(method, url, body)
      uri  = URI.parse(url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl       = uri.scheme == "https"
      http.open_timeout  = @timeout
      http.read_timeout  = @timeout
      http.write_timeout = @timeout

      req_class = { get: Net::HTTP::Get, post: Net::HTTP::Post,
                    put: Net::HTTP::Put, delete: Net::HTTP::Delete }
                  .fetch(method, Net::HTTP::Post)
      req = req_class.new(uri.request_uri)
      @headers.each { |k, v| req[k] = v }
      req.body = body.to_json if body && %i[post put patch].include?(method)

      http.request(req)
    end

    def parse_error_body(response)
      JSON.parse(response.body, symbolize_names: true)
    rescue JSON::ParserError
      { error: "UnknownError", message: "HTTP #{response.code}" }
    end

    def log(entry)
      @logger&.call(entry)
    end

    def elapsed_ms(start)
      (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000
    end
  end
end
