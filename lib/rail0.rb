# frozen_string_literal: true

# Entry point. Everything below is loaded with require_relative on purpose: the
# gem used to unshift lib/rail0 and lib/rail0/resources onto the GLOBAL $LOAD_PATH
# so its files could require each other by bare name ("request", "query", …).
# That put ~20 generic basenames at the FRONT of the search path for the whole
# process, so any gem loaded afterwards doing a bare `require "request"` silently
# got ours — order-dependent and effectively undiagnosable. require_relative needs
# no path at all. (#5)

require_relative "rail0/version"
require_relative "rail0/error_hints"
require_relative "rail0/api_error"
require_relative "rail0/default_logger"
require_relative "rail0/request"
require_relative "rail0/http_client"
require_relative "rail0/client"
require_relative "rail0/stablecoins"
