module Rail0
  # Raised for non-2xx responses from the RAIL0 API.
  class ApiError < StandardError
    # @return [Integer] HTTP status code (e.g. 404, 409, 422).
    attr_reader :status

    # @return [String] Machine-readable error identifier (e.g. "PaymentNotFound").
    attr_reader :error

    # @param status [Integer]
    # @param error [String]
    # @param message [String]
    def initialize(status, error, message)
      super(message)
      @status = status
      @error = error
    end
  end
end
