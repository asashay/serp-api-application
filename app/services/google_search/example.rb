module GoogleSearch
  module Example
    # A real capture: the renderer's output for this query, kept as returned.
    QUERY = "best matcha bar"
    # Captured through an Austin exit IP (config/locations.json).
    LOCATION = "Austin, Texas, United States"
    PATH = Rails.root.join("test/fixtures/google_search/example.html")

    def self.html
      File.read(PATH, encoding: "UTF-8")
    end

    # The playground's opening response. The page never changes, so it is
    # parsed once per process; as a saved example it took no time to fetch.
    def self.sample
      @sample ||= begin
        payload = Response.new(query: QUERY, location: location, request_id: "saved-example")
          .call(html, source: "fixture")
        metadata = payload.fetch(:search_metadata)
        payload.merge(
          elapsed_ms: 0,
          search_metadata: metadata.merge(created_at: metadata.fetch(:processed_at), total_time_taken: 0.0)
        ).freeze
      end
    end

    # nil (a page over Preview::LIMIT) is cached too, so it is not rebuilt per request.
    def self.location
      Location.find(LOCATION)
    end

    def self.preview_html
      return @preview_html if defined?(@preview_html)

      @preview_html = Preview.new(html).call
    end
  end
end
