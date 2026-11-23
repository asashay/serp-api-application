require_relative "boot"

require "rails"
require "action_controller/railtie"
require "action_view/railtie"
require "rails/test_unit/railtie"

Bundler.require(*Rails.groups)

module SerpApiDemo
  class Application < Rails::Application
    config.load_defaults 8.1
    config.filter_parameters += [ :q, :html ]
    config.action_dispatch.default_headers.merge!("Referrer-Policy" => "no-referrer")
  end
end
