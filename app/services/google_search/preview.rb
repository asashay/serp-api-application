require "nokogiri"

module GoogleSearch
  # A static, link-free copy of a captured results page for the playground's
  # preview frame. The page keeps its styles and inline images but loses every
  # script, embedded document, form target and link destination. The playground
  # shows it in a sandboxed iframe (no scripts, forms, popups or navigation), and
  # the CSP below stops it from loading anything at all.
  class Preview
    POLICY = "default-src 'none'; img-src data:; style-src 'unsafe-inline'; font-src data:; " \
      "form-action 'none'; base-uri 'none'".freeze
    REMOVED = %w[
      script noscript template iframe frame frameset object embed applet portal link meta base
      audio video source track canvas dialog
    ].freeze
    ATTRIBUTES = %w[
      class id style role alt title lang dir width height colspan rowspan align valign
      type placeholder value rows cols checked disabled readonly
      viewbox d fill stroke stroke-width stroke-linecap stroke-linejoin fill-rule clip-rule
      cx cy r rx ry x y x1 y1 x2 y2 points transform opacity focusable xmlns preserveaspectratio
    ].freeze
    # Links, buttons and fields look normal but do nothing when clicked.
    INERT = <<~CSS.freeze
      a, button, input, textarea, select, label, summary, [role=button], [role=link], [role=tab],
      [tabindex] { pointer-events: none !important; cursor: default !important; }
    CSS

    def initialize(html)
      @html = html
    end

    # The sanitized document, or nil when Nokogiri cannot parse the page. Its size
    # follows the captured page, which the renderer already caps at 5 MiB.
    def call
      document = Nokogiri::HTML5(@html)
      document.xpath("//comment()").each(&:remove)
      document.css(REMOVED.join(", ")).each(&:remove)
      document.traverse { |node| clean(node) if node.element? }
      document.css("style").each { |style| style.content = style.content.gsub(/@import[^;]*;?/i, "") }

      head = document.at_css("head") || document.root.prepend_child(document.create_element("head"))
      head.prepend_child(document.create_element("style", INERT))
      head.prepend_child(document.create_element("meta", "http-equiv" => "Content-Security-Policy", "content" => POLICY))
      head.prepend_child(document.create_element("meta", "charset" => "utf-8"))

      "<!doctype html>#{document.root.to_html}"
    rescue ArgumentError
      nil
    end

    private

    def clean(node)
      node.attribute_nodes.each do |attribute|
        name = attribute.name.downcase
        next if name.start_with?("aria-")
        next if name == "src" && attribute.value.start_with?("data:image/")
        next if ATTRIBUTES.include?(name) && !attribute.value.match?(/\A\s*(?:javascript|data|vbscript):/i)

        attribute.remove
      end
    end
  end
end
