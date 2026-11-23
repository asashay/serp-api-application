class SearchController < ActionController::API
  before_action :set_response_headers
  rescue_from GoogleSearch::Error, with: :render_search_error

  def show
    query = GoogleSearch::Query.parse(request.query_string)
    return invalid_query unless query
    return render_error("live_search_unavailable", "Use the Cloudflare Worker to run a live search.", 503) unless fixture_mode?
    unless query == GoogleSearch::Example::QUERY
      return render_error("fixture_query_unavailable", "The local fixture is available for Ruby on Rails guides.", 422)
    end

    render_capture(GoogleSearch::Example.html, query: query, source: "fixture", preview: request.path_parameters[:preview])
  end

  def example
    render_capture(GoogleSearch::Example.html, query: GoogleSearch::Example::QUERY, source: "fixture")
  end

  def parse
    return head :not_found unless ENV["CLOUDFLARE_CONTAINER"] == "1"

    payload = request.request_parameters
    query = GoogleSearch::Query.normalize(payload["query"])
    return invalid_query unless query

    render_capture(payload.fetch("html"), query: query, source: "google",
      preview: payload["preview"] == true, elapsed_ms: payload.fetch("elapsed_ms"))
  end

  private

  def fixture_mode?
    ENV["CLOUDFLARE_CONTAINER"] != "1"
  end

  def render_capture(html, query:, source:, preview: false, elapsed_ms: 0)
    payload = GoogleSearch::Response.new(query: query, request_id: request.request_id, elapsed_ms: elapsed_ms)
      .call(html, source: source)
    Rails.logger.info { "search outcome=ok source=#{source} elapsed_ms=#{payload.fetch(:elapsed_ms)}" }
    render json: payload
  end

  def set_response_headers
    response.set_header("Cache-Control", "no-store")
    response.set_header("Access-Control-Allow-Origin", "*") if request.path == "/search.json" || action_name == "example"
    response.set_header("Access-Control-Expose-Headers", "Retry-After, X-Request-Id") if request.path == "/search.json"
  end

  def invalid_query
    render_error("invalid_query", "Provide one search query (1 to 200 characters).", 400)
  end

  def render_search_error(error)
    Rails.logger.info { "search outcome=#{error.code}" }
    render_error(error.code, error.message, error.status)
  end

  def render_error(code, message, status)
    render json: { error: { code: code, message: message }, request_id: request.request_id }, status: status
  end
end
