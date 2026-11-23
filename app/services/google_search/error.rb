module GoogleSearch
  class Error < StandardError
    DETAILS = {
      upstream_challenge: [502, "Google returned a challenge page."],
      upstream_timeout: [504, "Google results took too long to load."],
      upstream_unavailable: [503, "Live search is temporarily unavailable."],
      unknown_layout: [502, "The search results layout could not be recognized."]
    }.freeze

    attr_reader :code, :status

    def initialize(code)
      @code = code
      @status, message = DETAILS.fetch(code)
      super(message)
    end
  end
end
