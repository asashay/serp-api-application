class CaptureController < ActionController::API
  before_action :set_response_headers
  rescue_from PageCapture::Renderer::Error, with: :render_capture_error

  def show
    url = PageCapture::Path.url(GoogleSearch::Query.parse(request.query_string))
    return invalid_path unless url
    return render_error("live_search_unavailable", "Use the Cloudflare Worker to run a live search.", 503) if deployed?
    return render_error("fixture_query_unavailable", "The local fixture is available for /.", 422) unless url == "#{PageCapture::Path::ORIGIN}/"

    render_example
  end

  def example
    render_example
  end

  def capture
    return head :not_found unless deployed?

    url = PageCapture::Path.url(params[:path])
    return invalid_path unless url

    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    final_url, html = PageCapture::Renderer.new.call(url)
    document = PageCapture::Document.new(html)
    elapsed_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000
    render_document(document, url: final_url, source: "lingorep",
      elapsed_ms: params[:elapsed_ms].to_i + elapsed_ms.round)
  end

  def health
    return head :not_found unless deployed?

    head PageCapture::Renderer.new.ready? ? :ok : :service_unavailable
  end

  private

  def deployed?
    ENV["CLOUDFLARE_CONTAINER"] == "1"
  end

  def render_example
    render_document(PageCapture::Document.example, url: "#{PageCapture::Path::ORIGIN}/", source: "fixture",
      elapsed_ms: 0)
  end

  def render_document(document, url:, source:, elapsed_ms:)
    payload = document.response(url: url, source: source, request_id: request.request_id, elapsed_ms: elapsed_ms)
    response.set_header("X-Search-Response", "1") if action_name == "capture"
    render json: payload
  end

  def set_response_headers
    response.set_header("Cache-Control", "no-store")
    if request.path.in?(%w[/search.json /example.json])
      response.set_header("Access-Control-Allow-Origin", "*")
      response.set_header("Access-Control-Expose-Headers", "Retry-After, X-Request-Id")
    end
  end

  def invalid_path
    render_error("invalid_query", "Enter a LingoRep page path (1 to 200 characters).", 400)
  end

  def render_capture_error(error)
    Rails.logger.info { "capture outcome=#{error.code}" }
    render_error(error.code, error.message, error.status)
  end

  def render_error(code, message, status)
    response.set_header("X-Search-Response", "1") if action_name == "capture"
    render json: { error: { code: code, message: message }, request_id: request.request_id }, status: status
  end
end
