module GoogleSearch
  class Response
    def initialize(query:, request_id:, elapsed_ms: 0)
      @query = query
      @request_id = request_id
      @started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      @elapsed_ms = elapsed_ms
    end

    def call(html, source:)
      results = Parser.new.call(html)
      {
        query: @query,
        organic_results: results.map(&:to_h),
        request_id: @request_id,
        elapsed_ms: @elapsed_ms + ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - @started_at) * 1000).round,
        source: source
      }
    end
  end
end
