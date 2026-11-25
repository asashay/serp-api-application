require "net/http"

module PageCapture
  class Renderer
    LIMIT = 5 * 1024 * 1024
    ENDPOINT = URI("http://127.0.0.1:3800")
    # The renderer's deadline plus headroom. renderer/server.py reads
    # RENDER_TIMEOUT_SECONDS with the same rules: finite and above 60, else 60.
    def self.deadline(value)
      seconds = Float(value.presence || 60)
      seconds.finite? && seconds > 60 ? seconds : 60.0
    rescue ArgumentError, TypeError
      60.0
    end

    READ_TIMEOUT = deadline(ENV["RENDER_TIMEOUT_SECONDS"]) + 4
    Error = Class.new(StandardError) do
      attr_reader :code, :status

      def initialize(code, message, status)
        super(message)
        @code = code
        @status = status
      end
    end

    # location: a name from config/locations.json; the renderer picks an exit
    # IP there. nil uses any exit IP.
    def call(url, location: nil)
      request = Net::HTTP::Post.new("/render", "Content-Type" => "application/json")
      request.body = JSON.generate({ url: url, location: location }.compact)
      http(read_timeout: READ_TIMEOUT).request(request) do |response|
        case response.code.to_i
        when 200
          html = +"".b
          response.read_body do |chunk|
            html << chunk
            raise unavailable if html.bytesize > LIMIT
          end
          html.force_encoding(Encoding::UTF_8)
          final_url = response["X-Page-Url"]
          raise unavailable if html.empty? || !html.valid_encoding? || !final_url&.start_with?("#{GoogleSearch::Query::ORIGIN}/")

          return [ final_url, html ]
        when 429
          raise Error.new("upstream_challenge", "Google returned a challenge page.", 502)
        when 504
          raise timeout
        else
          raise unavailable
        end
      end
    rescue Net::ReadTimeout
      raise timeout
    rescue IOError, SocketError, SystemCallError, Net::ProtocolError, Net::OpenTimeout
      raise unavailable
    end

    def ready?
      http(read_timeout: 7).get("/health").is_a?(Net::HTTPSuccess)
    rescue IOError, SocketError, SystemCallError, Net::ProtocolError, Net::OpenTimeout, Net::ReadTimeout
      false
    end

    private

    def http(read_timeout:)
      Net::HTTP.new(ENDPOINT.host, ENDPOINT.port, nil).tap do |connection|
        connection.open_timeout = 2
        connection.read_timeout = read_timeout
      end
    end

    def timeout
      Error.new("upstream_timeout", "Google results took too long to load.", 504)
    end

    def unavailable
      Error.new("upstream_unavailable", "Live search is temporarily unavailable.", 503)
    end
  end
end
