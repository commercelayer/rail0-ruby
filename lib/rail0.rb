rail0_dir     = File.join(__dir__, "rail0")
resources_dir = File.join(rail0_dir, "resources")

[__dir__, rail0_dir, resources_dir].each do |dir|
  $LOAD_PATH.unshift(dir) unless $LOAD_PATH.include?(dir)
end

require "rail0/version"
# Before api_error: ApiError#hint calls Rail0.describe_error.
require "rail0/error_hints"
require "rail0/api_error"
require "rail0/default_logger"
require "rail0/request"
require "rail0/http_client"
require "rail0/client"
require "rail0/stablecoins"
