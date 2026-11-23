Rails.application.configure do
  config.enable_reloading = false
  config.eager_load = true
  config.consider_all_requests_local = false
  config.assume_ssl = ENV["CLOUDFLARE_CONTAINER"] == "1"
  config.log_level = :info
  config.logger = ActiveSupport::TaggedLogging.logger($stdout)
  config.log_tags = [ :request_id ]

  if ENV["CLOUDFLARE_CONTAINER"] == "1"
    config.hosts << "serp-api-demo.alexoliynyk.me"
    config.hosts << "rails.internal"
  end
end
