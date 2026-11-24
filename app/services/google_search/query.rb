require "uri"

module GoogleSearch
  module Query
    ORIGIN = "https://www.google.com"
    PARAMETERS = %w[q location].freeze

    # [query, location] from a query string with one q and at most one
    # location, or nil. The location is returned as given; callers look it up
    # with Location.find so an unknown one gets its own error.
    def self.parse(query_string)
      pairs = URI.decode_www_form(query_string)
      keys = pairs.map(&:first)
      return unless keys.count("q") == 1 && keys.count("location") <= 1 && (keys - PARAMETERS).empty?

      values = pairs.to_h
      query = normalize(values["q"])
      [ query, values["location"] ] if query
    rescue ArgumentError
      nil
    end

    def self.normalize(value)
      return unless value.is_a?(String) && value.valid_encoding?

      query = value.gsub(/\A[[:space:]]+|[[:space:]]+\z/, "")
      query if query.length.between?(1, 200) && !query.match?(/[[:cntrl:]]|\uFFFD/)
    end

    # English results; a location also sets Google's country (gl) and place (uule).
    def self.url(value, location: nil)
      query = normalize(value)
      return unless query

      parameters = { q: query, hl: "en" }
      parameters.merge!(gl: location.gl, uule: location.uule) if location
      "#{ORIGIN}/search?#{URI.encode_www_form(parameters)}"
    end
  end
end
