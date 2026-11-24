require "net/http"

module PageCapture
  class Renderer
    LIMIT = 5 * 1024 * 1024
    ENDPOINT = URI("http://127.0.0.1:3800")
    Error = Class.new(StandardError) do
      attr_reader :code, :status

      def initialize(code, message, status)
        super(message)
        @code = code
        @status = status
      end
    end

    def call(url)
      request = Net::HTTP::Post.new("/render", "Content-Type" => "application/json")
      request.body = JSON.generate(url: url)
      http(read_timeout: 34).request(request) do |response|
        case response.code.to_i
        when 200
          html = +"".b
          response.read_body do |chunk|
            html << chunk
            raise unavailable if html.bytesize > LIMIT
          end
          html.force_encoding(Encoding::UTF_8)
          final_url = response["X-Page-Url"]
          raise unavailable if html.empty? || !html.valid_encoding? || !final_url&.start_with?("#{Path::ORIGIN}/")

          return [ final_url, html ]
        when 404
          raise Error.new("page_not_found", "That page could not be found.", 404)
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
      Error.new("upstream_timeout", "The page took too long to load.", 504)
    end

    def unavailable
      Error.new("upstream_unavailable", "The page renderer is temporarily unavailable.", 503)
    end
  end
end
