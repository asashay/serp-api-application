require "uri"

module GoogleSearch
  module Query
    def self.parse(query_string)
      pairs = URI.decode_www_form(query_string)
      return unless pairs.size == 1 && pairs.first.first == "q"

      normalize(pairs.first.last)
    rescue ArgumentError
      nil
    end

    def self.normalize(value)
      return unless value.is_a?(String) && value.valid_encoding?

      query = value.gsub(/\A[[:space:]]+|[[:space:]]+\z/, "")
      query if query.length.between?(1, 200) && !query.match?(/[[:cntrl:]]|\uFFFD/)
    end
  end
end
