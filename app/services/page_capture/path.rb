require "uri"

module PageCapture
  module Path
    ORIGIN = "https://lingorep.com"

    def self.url(value)
      path = GoogleSearch::Query.normalize(value)
      return if !path || path.match?(/\A(?:\/\/|[a-z][a-z\d+.-]*:)|[\\?#%]/i)

      segments = path.delete_prefix("/").split("/", -1)
      return if segments.intersect?(%w[. ..])

      "#{ORIGIN}/#{segments.map { |segment| URI.encode_uri_component(segment) }.join('/')}"
    end
  end
end
