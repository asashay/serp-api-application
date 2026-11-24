class PlaygroundController < ApplicationController
  def show
    @query = "/"
    document = PageCapture::Document.example
    @sample = document.response(url: "#{PageCapture::Path::ORIGIN}/", source: "fixture",
      request_id: "saved-example", elapsed_ms: 0)
    @api_origin = ENV.fetch("PUBLIC_ORIGIN") { request.base_url }
    @api_url = "#{@api_origin}/search.json?#{URI.encode_www_form(q: @query)}"
  end
end
