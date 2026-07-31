# frozen_string_literal: true

require "logger"

module Rail0
  # One log record emitted per request attempt.
  LogEntry = Struct.new(
    :method, :url, :duration_ms, :request_body,
    :status, :response_body, :error, :attempt, :will_retry,
    keyword_init: true
  )

  # Default logger for Rail0::Client's `logger:` option. A Logger subclass:
  # formats a Rail0::LogEntry into a one-line summary and logs it through the
  # standard Logger machinery, so #level, #formatter, and any IO/file logdev
  # all work normally instead of being reimplemented.
  #
  #   client = Rail0::Client.new(base_url: "https://api.rail0.xyz", logger: Rail0::DEFAULT_LOGGER)
  #   # [rail0] GET 200 https://.../payments/0x… 87ms
  #
  #   # Write to a file, only warnings and above:
  #   client = Rail0::Client.new(
  #     base_url: "https://api.rail0.xyz",
  #     logger:   Rail0::DefaultLogger.new("rail0.log", level: Logger::WARN)
  #   )
  class DefaultLogger < Logger
    def initialize(logdev = $stdout, *args, **kwargs)
      super
    end

    # The callable interface HttpClient expects: one Rail0::LogEntry per
    # request attempt. Routes to #error on failure so raising the level past
    # DEBUG still surfaces failed requests, and to #debug otherwise.
    def call(entry)
      entry.error ? error(message_for(entry)) : debug(message_for(entry))
    end

    private

    def message_for(entry)
      flag        = entry.error ? " ERROR" : ""
      status_part = entry.status ? " #{entry.status}" : ""
      attempt_part =
        if entry.attempt && (entry.attempt > 1 || entry.will_retry)
          retry_part = entry.will_retry ? ", retrying" : ""
          " [attempt #{entry.attempt}#{retry_part}]"
        else
          ""
        end

      parts = ["[rail0]#{flag}#{attempt_part} #{entry.method}#{status_part} #{entry.url} #{entry.duration_ms.round}ms"]
      parts << "-> #{entry.request_body.inspect}" if entry.request_body
      parts << "<- #{entry.response_body.inspect}" if entry.response_body
      parts << "! #{entry.error}"                  if entry.error
      parts.join(" ")
    end
  end

  # Ready-to-use DefaultLogger writing to $stdout at the default level, shared
  # so callers who just want the built-in output don't need to instantiate
  # their own. Frozen -- it can't be reconfigured (no #level=, no #formatter=)
  # since that would leak across every Client sharing it; anyone wanting a
  # different IO/level should build their own via DefaultLogger.new(...).
  #
  #   client = Rail0::Client.new(base_url: "https://api.rail0.xyz", logger: Rail0::DEFAULT_LOGGER)
  DEFAULT_LOGGER = DefaultLogger.new.freeze

  # The `logger:` used when the caller doesn't pass one. Discards every entry,
  # so HttpClient can always unconditionally call `logger.call(entry)` without
  # ever checking whether logging is actually configured.
  class NullLogger
    def call(_entry); end
  end

  # NullLogger is stateless, so every HttpClient built without an explicit
  # `logger:` shares this one frozen instance instead of allocating its own.
  NULL_LOGGER = NullLogger.new.freeze
end
