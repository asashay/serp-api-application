class PlaygroundController < ApplicationController
  def show
    @query = GoogleSearch::Example::QUERY
    html = GoogleSearch::Example.html
    @sample = GoogleSearch::Response.new(query: @query, request_id: "saved-example").call(html, source: "fixture")
    @sample[:elapsed_ms] = 0
    @preview = GoogleSearch::Preview.new.call(html)
    @api_origin = ENV["CLOUDFLARE_CONTAINER"] == "1" ? "https://serp-api-demo.alexoliynyk.me" : request.base_url
    @api_url = "#{@api_origin}/search.json?#{URI.encode_www_form(q: @query)}"
  end
end
