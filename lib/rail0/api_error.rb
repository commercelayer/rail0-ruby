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
    attr_reader :status, :error, :title, :detail

    # @param status [Integer]
    # @param error [String]
    # @param message [String] The detail; kept positional for compatibility.
    # @param title [String, nil]
    def initialize(status, error, message, title: nil)
      super(message)
      @status = status
      @error = error
      @title = title
      @detail = message
      freeze
    end

    # This SDK's actionable next step for the error, or nil when it has none.
    # @return [String, nil]
    def hint
      Rail0.describe_error(error)
    end
  end
end
