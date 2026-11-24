class PlaygroundController < ApplicationController
  def show
    @query = GoogleSearch::Example::QUERY
    @location = GoogleSearch::Example::LOCATION
    @sample = GoogleSearch::Example.sample
    @preview_html = GoogleSearch::Example.preview_html
    @api_origin = ENV.fetch("PUBLIC_ORIGIN") { request.base_url }
    @api_url = "#{@api_origin}/search.json?#{URI.encode_www_form(q: @query, location: @location)}"
  end
end
