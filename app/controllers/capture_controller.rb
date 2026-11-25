class CaptureController < ActionController::API
  before_action :set_response_headers
  rescue_from PageCapture::Renderer::Error, GoogleSearch::Error, with: :render_search_error

  def show
    query, location_name = GoogleSearch::Query.parse(request.query_string)
    return invalid_query unless query
    location = GoogleSearch::Location.find(location_name) if location_name
    return invalid_location if location_name && !location
    return render_error("live_search_unavailable", "Use the Cloudflare Worker to run a live search.", 503) if deployed?
    return render_live(query, location) if local_live_search?
    unless query == GoogleSearch::Example::QUERY && [ nil, GoogleSearch::Example.location ].include?(location)
      return render_error("fixture_query_unavailable",
        "The local fixture is available for #{GoogleSearch::Example::QUERY} in #{GoogleSearch::Example::LOCATION}.", 422)
    end

    render_example
  end

  def example
    render_example
  end

  def capture
    return head :not_found unless deployed?

    query = GoogleSearch::Query.normalize(params[:query])
    return invalid_query unless query
    location = GoogleSearch::Location.find(params[:location]) unless params[:location].nil?
    return invalid_location if !params[:location].nil? && !location

    render_live(query, location, queued_ms: params[:elapsed_ms].to_i)
  end

  def health
    return head :not_found unless deployed?

    head PageCapture::Renderer.new.ready? ? :ok : :service_unavailable
  end

  private

  def deployed?
    ENV["CLOUDFLARE_CONTAINER"] == "1"
  end

  # Lets a local run (for example the production image under Docker) send
  # searches through its own renderer. There is no Worker quota gate here.
  def local_live_search?
    ENV["LOCAL_LIVE_SEARCH"] == "1"
  end

  def render_live(query, location, queued_ms: 0)
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    renderer = PageCapture::Renderer.new
    begin
      _final_url, html = renderer.call(GoogleSearch::Query.url(query, location: location), location: location&.name)
    ensure
      pass_render_log(renderer)
    end
    elapsed_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000
    render_capture(html, query: query, location: location, source: "google", elapsed_ms: queued_ms + elapsed_ms.round)
  end

  def render_example
    render_capture(GoogleSearch::Example.html, query: GoogleSearch::Example::QUERY,
      location: GoogleSearch::Example.location, source: "fixture")
  end

  def render_capture(html, query:, source:, location: nil, elapsed_ms: 0)
    payload = GoogleSearch::Response.new(query: query, location: location, request_id: request.request_id,
      elapsed_ms: elapsed_ms)
      .call(html, source: source)
    Rails.logger.info { "search outcome=ok source=#{source} elapsed_ms=#{payload.fetch(:elapsed_ms)}" }
    payload[:preview_html] = GoogleSearch::Preview.new(html).call if preview?
    response.set_header("X-Search-Response", "1") if action_name == "capture"
    render json: payload
  end

  # The playground shows a sanitized copy of the page next to the JSON. The
  # public API never includes it; in production the Worker says which is which.
  def preview?
    if action_name == "capture"
      params[:preview] == true
    else
      request.path == "/playground/search"
    end
  end

  def set_response_headers
    response.set_header("Cache-Control", "no-store")
    if request.path.in?(%w[/search.json /example.json])
      response.set_header("Access-Control-Allow-Origin", "*")
      response.set_header("Access-Control-Expose-Headers", "Retry-After, X-Request-Id")
    end
  end

  def invalid_query
    render_error("invalid_query", "Provide one search query (1 to 200 characters).", 400)
  end

  def invalid_location
    render_error("invalid_location", "Use one of these locations: #{GoogleSearch::Location.names.join('; ')}.", 400)
  end

  # Hands the renderer's timing summary to the Worker for its logs. Only the
  # internal capture route answers the Worker; the public API never shows it.
  def pass_render_log(renderer)
    log = renderer.log if renderer.respond_to?(:log)
    return unless log.present?

    Rails.logger.info { log }
    response.set_header(PageCapture::Renderer::LOG_HEADER, log) if action_name == "capture"
  end

  def render_search_error(error)
    Rails.logger.info { "search outcome=#{error.code}" }
    render_error(error.code, error.message, error.status)
  end

  def render_error(code, message, status)
    response.set_header("X-Search-Response", "1") if action_name == "capture"
    render json: { error: { code: code, message: message }, request_id: request.request_id }, status: status
  end
end
