require "nokogiri"
require "uri"

module GoogleSearch
  class Parser
    LIMIT = 10
    PAGE_LIMIT = 10
    GOOGLE_ORIGIN = "https://www.google.com"
    GOOGLE_HOSTS = %w[www.google.com google.com].freeze
    SNIPPET = ".VwiC3b, [data-sncf], .IsZvec, .st".freeze
    # The "6 days ago — " prefix Google puts in front of some snippets.
    SNIPPET_DATE = "span.LEwnzc, span.YrbPuc".freeze
    # A cite is a breadcrumb ("https://example.com › docs") only when it starts
    # with a host. Forum and video cards put "7 comments · 1 hour ago" there.
    BREADCRUMB = %r{\A(?:https?://)?[\p{Alnum}-]+(?:\.[\p{Alnum}-]+)+(?:[\s/›]|\z)}
    CITE_DATE = /\A(?:\d+\+? \w+ ago|\p{Alpha}{3,9}\.? \d{1,2}, \d{4}|\d{1,2} \p{Alpha}{3,9}\.? \d{4}|yesterday|today)\z/i

    Result = Data.define(:position, :title, :link, :redirect_link, :displayed_link, :source,
      :favicon, :date, :snippet, :snippet_highlighted_words) do
      # Optional fields are left out when Google shows nothing for them;
      # snippet stays, as it always has, even when it is null.
      def to_h
        super.reject { |key, value| key != :snippet && (value.nil? || value == []) }
      end
    end
    Page = Data.define(:results, :information, :pagination)

    # Organic results only, for callers that need nothing else.
    def call(html)
      parse(html).results
    end

    def parse(html)
      page = parse_document(html)
      raise Error.new(:upstream_challenge) if challenge?(page)

      results = organic_results(page)
      raise Error.new(:unknown_layout) unless results.any? || no_results?(page)

      Page.new(results, information(page), pagination(page))
    end

    private

    def parse_document(html)
      Nokogiri::HTML5(html)
    rescue ArgumentError
      raise Error.new(:unknown_layout)
    end

    def organic_results(page)
      results = []
      seen = {}
      page.css("#rso a h3").each do |heading|
        anchor = heading.ancestors("a").first
        title = normalize(heading.text)
        link, redirect_link = result_links(anchor)
        next if title.empty? || !link || seen[link]

        next unless anchor.ancestors("div.g, div.yuRUbf, div.Gx5Zad, div[data-snhf]").any?

        seen[link] = true
        results << result(results.length + 1, title, link, redirect_link, card(anchor))
        break if results.length == LIMIT
      end
      results
    end

    # The largest block around the result that holds no other result heading.
    # Newer layouts split the title row and the snippet into sibling blocks.
    def card(anchor)
      anchor.ancestors.take_while { |node| node.element? && node["id"] != "rso" }
        .take_while { |node| node.css("a h3").size == 1 }.last || anchor
    end

    def result(position, title, link, redirect_link, card)
      snippet_node = card.at_css(SNIPPET)&.dup
      date_node = snippet_node&.at_css(SNIPPET_DATE)
      date = normalize(date_node.text).sub(/[[:space:]]*[—–-]\z/, "") if date_node
      date_node&.remove
      snippet = normalize(snippet_node&.text.to_s)
      displayed_link, cite_date = cite_details(card)

      Result.new(
        position: position,
        title: title,
        link: link,
        redirect_link: redirect_link,
        displayed_link: displayed_link,
        source: presence(normalize(card.at_css("span.VuuXrf")&.text.to_s)),
        favicon: favicon(card),
        date: presence(date.to_s) || cite_date,
        snippet: presence(snippet),
        snippet_highlighted_words: snippet_node ? snippet_node.css("em").map { |node| normalize(node.text) }.reject(&:empty?).uniq : []
      )
    end

    # [breadcrumb, date] from the card's cite: "https://www.youtube.com · Jan 26, 2021"
    # gives both, "7 comments · 1 hour ago" only the date.
    def cite_details(card)
      parts = normalize(card.at_css("cite")&.text.to_s).split(/[[:space:]]+·[[:space:]]+/)
      breadcrumb = parts.shift if parts.first&.match?(BREADCRUMB)
      [ breadcrumb, parts.reverse.find { |part| part.match?(CITE_DATE) } ]
    end

    # [link, redirect_link]. The renderer replaces Google's opaque /goto
    # links with their destinations and keeps the original in data-goto.
    # A /goto link it could not resolve is returned as both.
    def result_links(anchor)
      href = anchor["href"]
      return if href.nil?

      url = parse_url(href)
      if google_path?(url, "/goto")
        goto = absolute_google_url(href)
        return [ goto, goto ]
      end

      redirect = absolute_google_url(anchor["data-goto"]) if anchor["data-goto"]
      redirect = nil unless redirect && google_path?(parse_url(redirect), "/goto")
      if google_path?(url, "/url")
        redirect = absolute_google_url(href)
        target = URI.decode_www_form(url.query.to_s).to_h.values_at("q", "url").compact.first
        url = parse_url(target)
      end
      return unless web_url?(url)

      [ url.to_s, redirect ]
    rescue ArgumentError, URI::InvalidURIError
      nil
    end

    # Browsers accept links with raw spaces, non-ASCII or characters such as
    # "|" and "{}", and resolved /goto destinations arrive that way. URI.parse
    # does not, so those bytes are percent-encoded first instead of the result
    # being dropped. Existing escapes are kept; a "%" that starts none and
    # every "#" after the first are encoded too.
    URL_UNSAFE = %r{%(?![0-9A-Fa-f]{2})|[^A-Za-z0-9\-._~:/?#@!$&'()*+,;=%]}
    def parse_url(value)
      url, hash, fragment = value.to_s.strip.partition("#")
      url = "#{url}#{hash}#{fragment.gsub('#', '%23')}"
      URI.parse(url.gsub(URL_UNSAFE) { |char| char.bytes.map { |byte| format("%%%02X", byte) }.join })
    end

    def favicon(card)
      src = card.at_css("img.XNo5Ab")&.[]("src").to_s
      src if src.start_with?("data:image/") || web_url?(parse_url(src))
    rescue URI::InvalidURIError
      nil
    end

    def information(page)
      stats = normalize(page.at_css("#result-stats")&.text.to_s)
      query = page.at_css("textarea[name=q]")&.text || page.at_css("input[name=q]")&.[]("value")
      {
        query_displayed: presence(normalize(query.to_s)),
        total_results: stats[/([\d,.]+)\s+results?\b/i, 1]&.delete(",.")&.to_i,
        time_taken_displayed: stats[/\(([\d.]+)\s*s(?:econds?)?\)/, 1]&.to_f
      }.compact
    end

    def pagination(page)
      nav = page.css("[role=navigation]").find { |node| node.at_css('a#pnnext, a[aria-label^="Page "]') }
      return {} unless nav

      pages = nav.css('a[aria-label^="Page "]').filter_map do |link|
        number = link["aria-label"][/\APage (\d+)\z/, 1]
        url = search_page_url(link["href"])
        [ number, url ] if number && url
      end.first(PAGE_LIMIT).to_h
      {
        current: nav.css("td").find { |cell| !cell.at_css("a") && cell.text.strip.match?(/\A\d+\z/) }&.text.to_i || 1,
        next: search_page_url(nav.at_css("a#pnnext")&.[]("href")),
        other_pages: (pages unless pages.empty?)
      }.compact
    end

    # Pagination links stay on Google's search page.
    def search_page_url(href)
      url = absolute_google_url(href) if href
      url if url && google_path?(URI.parse(url), "/search")
    rescue URI::InvalidURIError
      nil
    end

    def challenge?(page)
      page.at_css('form#captcha-form, form[action*="/sorry/"], iframe[src*="/recaptcha/"]')
    end

    def no_results?(page)
      page.css("#topstuff, #search").any? do |node|
        node.text.match?(/did not match any documents|no results found/i)
      end
    end

    def absolute_google_url(href)
      URI.join(GOOGLE_ORIGIN, parse_url(href).to_s).to_s
    rescue ArgumentError, URI::InvalidURIError
      nil
    end

    def google_path?(url, path)
      url.path == path && (url.host.nil? || GOOGLE_HOSTS.include?(url.host))
    end

    def web_url?(url)
      url.is_a?(URI::HTTP) && url.host && url.userinfo.nil?
    end

    def presence(value)
      value unless value.empty?
    end

    def normalize(value)
      value.gsub(/[[:space:]]+/, " ").strip
    end
  end
end
