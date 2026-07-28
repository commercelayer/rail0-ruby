# frozen_string_literal: true

module Rail0
  # Raised for non-2xx responses from the RAIL0 API.
  class ApiError < StandardError
    # @!attribute [r] status
    #   @return [Integer] HTTP status code (e.g. 404, 409, 422).
    # @!attribute [r] error
    #   @return [String] Machine-readable error identifier (e.g. "PaymentNotFound").
    attr_reader :status, :error

    # @param status [Integer]
    # @param error [String]
    # @param message [String]
    def initialize(status, error, message)
      super(message)
      @status = status
      @error = error
      freeze
    end
  end
end
