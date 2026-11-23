require "nokogiri"
require "uri"

module GoogleSearch
  class Parser
    LIMIT = 10
    Result = Data.define(:position, :title, :link, :snippet)

    def call(html)
      page = Nokogiri::HTML5(html)
      raise Error.new(:upstream_challenge) if challenge?(page)

      results = organic_results(page)
      return results if results.any? || no_results?(page)

      raise Error.new(:unknown_layout)
    end

    private

    def organic_results(page)
      results = []
      seen = {}
      page.css("#rso a h3").each do |heading|
        anchor = heading.ancestors("a").first
        title = normalize(heading.text)
        link = result_url(anchor["href"])
        next if title.empty? || !link || seen[link]

        seen[link] = true
        card = anchor.ancestors.find do |node|
          node.matches?("div.g, div.MjjYud, div.Gx5Zad, div[data-snhf]")
        end
        snippet = normalize(card&.at_css(".VwiC3b, [data-sncf], .IsZvec, .st")&.text.to_s)
        results << Result.new(results.length + 1, title, link, snippet.empty? ? nil : snippet)
        break if results.length == LIMIT
      end
      results
    end

    def challenge?(page)
      page.at_css('form#captcha-form, form[action*="/sorry/"], iframe[src*="/recaptcha/"]') ||
        page.text.include?("Our systems have detected unusual traffic")
    end

    def no_results?(page)
      message = page.at_css("#topstuff, #search")&.text.to_s
      message.match?(/did not match any documents|no results found/i)
    end

    def result_url(href)
      return if href.nil?

      url = URI.parse(href)
      if url.path == "/url" && (url.host.nil? || %w[www.google.com google.com].include?(url.host))
        target = URI.decode_www_form(url.query.to_s).to_h.values_at("q", "url").compact.first
        url = URI.parse(target.to_s)
      end
      return unless url.is_a?(URI::HTTP) && url.host && url.userinfo.nil?

      url.to_s
    rescue ArgumentError, URI::InvalidURIError
      nil
    end

    def normalize(value)
      value.gsub(/[[:space:]]+/, " ").strip
    end
  end
end
