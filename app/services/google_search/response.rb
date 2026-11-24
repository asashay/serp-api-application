module GoogleSearch
  class Response
    # Every capture asks google.com for English desktop results (Query.url).
    PARAMETERS = { engine: "google", google_domain: "google.com", hl: "en", device: "desktop" }.freeze

    def initialize(query:, request_id:, location: nil, elapsed_ms: 0)
      @query = query
      @location = location
      @request_id = request_id
      @started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      @elapsed_ms = elapsed_ms
    end

    def call(html, source:)
      page = Parser.new.parse(html)
      elapsed_ms = @elapsed_ms + ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - @started_at) * 1000).round
      {
        query: @query,
        search_metadata: metadata(elapsed_ms),
        search_parameters: parameters,
        search_information: page.information.presence,
        organic_results: page.results.map(&:to_h),
        pagination: page.pagination.presence,
        request_id: @request_id,
        elapsed_ms: elapsed_ms,
        source: source
      }.compact
    end

    private

    # SerpApi's order. A location also says where the search ran and its country.
    def parameters
      located = { location_requested: @location.name, location_used: @location.name } if @location
      { engine: PARAMETERS[:engine], q: @query, **located.to_h, google_domain: PARAMETERS[:google_domain],
        hl: PARAMETERS[:hl], gl: @location&.gl, device: PARAMETERS[:device] }.compact
    end

    # elapsed_ms covers the whole search (the Worker's queue time, the capture
    # and parsing), so the search was created that long before it was processed.
    def metadata(elapsed_ms)
      processed_at = Time.now.utc
      {
        id: @request_id,
        status: "Success",
        created_at: (processed_at - (elapsed_ms / 1000.0)).iso8601(3),
        processed_at: processed_at.iso8601(3),
        google_url: Query.url(@query, location: @location),
        total_time_taken: (elapsed_ms / 1000.0).round(3)
      }
    end
  end
end
