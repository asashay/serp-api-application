require "nokogiri"

module PageCapture
  class Document
    EXAMPLE = Rails.root.join("test/fixtures/page_capture/lingorep.html")

    def self.example
      new(File.read(EXAMPLE, encoding: "UTF-8"))
    end

    def initialize(html)
      @document = Nokogiri::HTML5(html)
    end

    def response(url:, source:, request_id:, elapsed_ms:)
      {
        url: url,
        title: normalized(@document.title),
        description: normalized(@document.at_css('meta[name="description"]')&.[]("content")),
        headings: @document.css("body h1, body h2, body h3, body h4, body h5, body h6").filter_map do |node|
          text = normalized(node.text)
          { level: node.name.delete_prefix("h").to_i, text: text } if text
        end,
        request_id: request_id,
        elapsed_ms: elapsed_ms,
        source: source
      }
    end

    private

    def normalized(text)
      text.to_s.gsub(/[[:space:]]+/, " ").strip.presence
    end
  end
end
