# frozen_string_literal: true

module Rail0
  # Raised for non-2xx responses from the RAIL0 gateway, mirroring the code/title/detail
  # triple the gateway answers with. `detail` is written to be shown to a user; `hint` is
  # this SDK's own advice, present only for codes worth adding a next step to.
  class ApiError < StandardError
    # @!attribute [r] status
    #   @return [Integer] HTTP status code (e.g. 404, 409, 422).
    # @!attribute [r] error
    #   @return [String] The specific condition, and the only field to branch on — e.g.
    #     "not_capturable", "insufficient_token_balance", "insufficient_gas_funds".
    # @!attribute [r] title
    #   @return [String, nil] Short label for the failure, e.g. "Not enough balance".
    # @!attribute [r] detail
    #   @return [String, nil] One or two sentences fit to show a user verbatim. Also this
    #     exception's message.
    # @!attribute [r] retry_after
    #   @return [Integer, nil] Seconds the gateway asked the caller to wait, from the
    #     `Retry-After` header — present on a 429 (`error == "rate_limited"`) and nil
    #     otherwise. Surfaced because the alternative is a caller guessing: the SDK used
    #     to drop the header, so "rate limited" arrived with no idea of for how long.
    #
    #     Note it is the WHOLE window the gateway throttles over, not the time left in it
    #     — the limiter sends its period verbatim — so it is an upper bound on the wait,
    #     not a measurement. Rail0::Backoff clamps it for that reason.
    attr_reader :status, :error, :title, :detail, :retry_after

    # @param status [Integer]
    # @param error [String]
    # @param message [String] The detail; kept positional for compatibility.
    # @param title [String, nil]
    # @param retry_after [Integer, nil]
    def initialize(status, error, message, title: nil, retry_after: nil)
      super(message)
      @status = status
      @error = error
      @title = title
      @detail = message
      @retry_after = retry_after
      freeze
    end

    # This SDK's actionable next step for the error, or nil when it has none.
    # @return [String, nil]
    def hint
      Rail0.describe_error(error)
    end
  end
end
