# frozen_string_literal: true

module Rail0
  # Raised for non-2xx responses from the RAIL0 gateway.
  #
  # The gateway answers every error with a code/title/detail triple; this mirrors it.
  # Show `detail` to a user and `title` as a heading: both come from the gateway's error
  # catalogue, so the same condition always reads the same way whichever endpoint
  # surfaced it. `hint` is this SDK's own advice — a supplement, present only for codes
  # worth adding a next step to.
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
    attr_reader :status, :error, :title, :detail

    # @param status [Integer]
    # @param error [String]
    # @param message [String] the detail; kept as the positional argument it has always been
    # @param title [String, nil]
    def initialize(status, error, message, title: nil)
      super(message)
      @status = status
      @error = error
      @title = title
      @detail = message
      freeze
    end

    # This SDK's actionable next step for the error, or nil when the code isn't one it
    # knows. A SUPPLEMENT to #detail, which the gateway always sends.
    #
    # @return [String, nil]
    def hint
      Rail0.describe_error(error)
    end
  end
end
