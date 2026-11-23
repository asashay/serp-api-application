module GoogleSearch
  class Preview
    TAGS = %w[a article b blockquote br cite dd div dl dt em h1 h2 h3 h4 li main ol p section small span strong ul].freeze
    REMOVED = "script, style, iframe, object, embed, template, svg, math, form, noscript"
    STYLE = <<~CSS.freeze
      :root { color-scheme: light; }
      * { box-sizing: border-box; }
      body { color: #292e39; font: 14px/1.55 system-ui, sans-serif; margin: 0; padding: 24px; overflow-wrap: anywhere; }
      h1, h2, h3, h4, p { margin: 0; }
      h3 { color: #263c94; font-size: 1.075rem; font-weight: 650; line-height: 1.35; margin: .3em 0; }
      cite { color: #626b7c; display: block; font-size: .82rem; font-style: normal; }
      a { color: inherit; text-decoration: none; }
      #rso > div { border-bottom: 1px solid #eef0f3; margin-bottom: 15px; padding-bottom: 15px; }
      #rso > div:last-child { border: 0; margin: 0; padding-bottom: 0; }
      .VwiC3b, .IsZvec, .st { color: #50596a; }
      @media (max-width: 465px) { body { padding: 17px; } }
    CSS

    def call(html)
      document = Nokogiri::HTML5(html)
      document.css(REMOVED).remove
      roots = document.css("#topstuff, #search, #rso").reject do |node|
        node.ancestors("#topstuff, #search, #rso").any?
      end
      content = Rails::HTML5::SafeListSanitizer.new.sanitize(
        roots.map(&:to_html).join, tags: TAGS, attributes: %w[class id]
      )
      frame(content)
    end

    private

    def frame(content)
      <<~HTML
        <!doctype html>
        <html lang="en"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; form-action 'none'; base-uri 'none'">
        <style>#{STYLE}</style></head><body>#{content}</body></html>
      HTML
    end
  end
end
