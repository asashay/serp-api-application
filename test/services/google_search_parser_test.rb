require "minitest/autorun"
require_relative "../../app/services/google_search/error"
require_relative "../../app/services/google_search/parser"

class GoogleSearchParserTest < Minitest::Test
  def setup
    @parser = GoogleSearch::Parser.new
  end

  def test_example_results_keep_source_order
    html = File.read(File.expand_path("../fixtures/google_search/example.html", __dir__), encoding: "UTF-8")
    results = @parser.call(html)
    assert_equal (1..5).to_a, results.map(&:position)
    assert_equal "The 9 Best Matcha in Houston | MyBestHouston", results.first.title
    assert_equal "https://mybesthouston.com/matcha/", results.first.link
    assert_match "The main points in one table", results.first.snippet
  end

  def test_links_keep_the_google_redirect_alongside_the_destination
    html = <<~HTML
      <div id="rso">
        <div class="g"><a href="/goto?url=CAESabc"><h3>Unresolved</h3></a></div>
        <div class="g"><a href="https://example.com/a" data-goto="https://www.google.com/goto?url=CAESdef"><h3>Resolved</h3></a></div>
        <div class="g"><a href="https://example.com/b" data-goto="https://evil.example/goto?url=x"><h3>Bad marker</h3></a></div>
        <div class="g"><a href="/url?q=https%3A%2F%2Fexample.com%2Fc"><h3>Old redirect</h3></a></div>
        <div class="g"><a href="https://example.com/d"><h3>Direct</h3></a></div>
      </div>
    HTML
    links = @parser.call(html).map { |result| [ result.link, result.redirect_link ] }
    assert_equal [
      [ "https://www.google.com/goto?url=CAESabc", "https://www.google.com/goto?url=CAESabc" ],
      [ "https://example.com/a", "https://www.google.com/goto?url=CAESdef" ],
      [ "https://example.com/b", nil ],
      [ "https://example.com/c", "https://www.google.com/url?q=https%3A%2F%2Fexample.com%2Fc" ],
      [ "https://example.com/d", nil ]
    ], links
  end

  def test_keeps_links_with_characters_uri_parse_rejects
    html = <<~HTML
      <div id="rso">
        <div class="g"><a href="https://de.wikipedia.org/wiki/Kaffeemühle" data-goto="https://www.google.com/goto?url=CAESabc"><h3>Umlaut</h3></a></div>
        <div class="g"><a href="https://example.com/a b|c{d}?q=x y"><h3>Spaces and pipes</h3></a></div>
        <div class="g"><a href="https://example.com/%C3%A9t%C3%A9"><h3>Escaped</h3></a></div>
        <div class="g"><a href="https://example.com/100%/a%zz#b#c"><h3>Stray percent and hash</h3></a></div>
      </div>
    HTML
    results = @parser.call(html)
    assert_equal [ 1, 2, 3, 4 ], results.map(&:position)
    assert_equal [
      [ "https://de.wikipedia.org/wiki/Kaffeem%C3%BChle", "https://www.google.com/goto?url=CAESabc" ],
      [ "https://example.com/a%20b%7Cc%7Bd%7D?q=x%20y", nil ],
      [ "https://example.com/%C3%A9t%C3%A9", nil ],
      [ "https://example.com/100%25/a%25zz#b%23c", nil ]
    ], results.map { |result| [ result.link, result.redirect_link ] }
  end

  def test_extracts_result_details_and_omits_missing_ones
    html = <<~HTML
      <div id="rso">
        <div class="MjjYud"><div class="N54PNb">
          <div class="kb0PBd" data-snhf="0"><div class="yuRUbf">
            <a href="https://example.com/a"><h3>First</h3></a>
            <span class="VuuXrf">Example Site</span><cite>https://example.com › a</cite>
            <img class="XNo5Ab" src="data:image/png;base64,AAAA">
          </div></div>
          <div class="kb0PBd" data-sncf="1"><div class="VwiC3b">
            <span class="YrbPuc"><span>Mar 17, 2026</span> — </span>A <em>coffee</em> guide with <em>coffee</em> and <em>grinders</em>.
          </div></div>
        </div></div>
        <div class="g"><a href="https://example.com/b"><h3>Second</h3></a></div>
      </div>
    HTML
    first, second = @parser.call(html)
    assert_equal "https://example.com › a", first.displayed_link
    assert_equal "Example Site", first.source
    assert_equal "data:image/png;base64,AAAA", first.favicon
    assert_equal "Mar 17, 2026", first.date
    assert_equal "A coffee guide with coffee and grinders.", first.snippet
    assert_equal [ "coffee", "grinders" ], first.snippet_highlighted_words
    assert_equal({ position: 2, title: "Second", link: "https://example.com/b", snippet: nil }, second.to_h)
  end

  def test_reads_live_layouts_with_snippets_details_and_pagination
    expected = {
      "goto_unresolved.html" => [ 6, 0, 25_600 ],
      "goto_mixed.html" => [ 9, 6, 165 ],
      "goto_mostly_unresolved.html" => [ 7, 1, 99 ]
    }
    expected.each do |name, (count, resolved, total)|
      page = @parser.parse(live_fixture(name))
      results = page.results
      assert_equal count, results.size, name
      assert_equal resolved, results.count { |result| result.link != result.redirect_link }, name
      assert results.all? { |result| result.snippet && result.source && result.redirect_link }, name
      assert results.all? { |result| result.displayed_link.nil? || result.displayed_link.start_with?("https://") }, name
      assert results.all? { |result| result.link.start_with?("https://", "http://") }, name
      assert_equal total, page.information[:total_results], name
      assert_kind_of Float, page.information[:time_taken_displayed], name
      assert_equal 1, page.pagination[:current], name
      assert_equal (2..10).map(&:to_s), page.pagination[:other_pages].keys, name
      assert page.pagination[:next].start_with?("https://www.google.com/search?"), name
    end
  end

  def test_live_layout_details_for_one_result
    page = @parser.parse(live_fixture("goto_unresolved.html"))
    result = page.results.first
    assert_equal "Food & Wine", result.source
    assert_equal "6 days ago", result.date
    assert result.snippet.start_with?("5-Star Ratings")
    assert_equal [ "OXO Brew Conical Burr Coffee Grinder, $99" ], result.snippet_highlighted_words
    assert result.favicon.start_with?("data:image/png;base64,")
    assert_equal "best coffee grinder", page.information[:query_displayed]
  end

  def test_forum_cards_have_no_breadcrumb_but_keep_their_date
    reddit = @parser.call(live_fixture("goto_unresolved.html")).find { |result| result.source == "Reddit · r/pourover" }
    assert_nil reddit.displayed_link
    assert_equal "1 hour ago", reddit.date

    stack = @parser.call(live_fixture("goto_mixed.html")).find { |result| result.source == "Stack Overflow" }
    assert_nil stack.displayed_link
    assert_equal "6 years ago", stack.date
  end

  def test_splits_a_breadcrumb_and_date_cite
    html = <<~HTML
      <div id="rso"><div class="g"><a href="https://example.com/v"><h3>Video</h3></a>
        <cite>https://www.youtube.com · Jan 26, 2021</cite></div></div>
    HTML
    result = @parser.call(html).first
    assert_equal "https://www.youtube.com", result.displayed_link
    assert_equal "Jan 26, 2021", result.date
  end

  def test_pagination_ignores_links_off_google_search
    html = <<~HTML
      <div id="rso"><div class="g"><a href="https://example.com/"><h3>Only</h3></a></div></div>
      <div role="navigation"><table role="presentation"><tr>
        <td>1</td>
        <td><a aria-label="Page 2" href="/search?q=a&amp;start=10">2</a></td>
        <td><a aria-label="Page 3" href="https://evil.example/search?q=a">3</a></td>
        <td><a id="pnnext" href="/url?q=https://evil.example/">Next</a></td>
      </tr></table></div>
    HTML
    assert_equal({ current: 1, other_pages: { "2" => "https://www.google.com/search?q=a&start=10" } },
      @parser.parse(html).pagination)
  end

  def test_unwraps_google_redirects_and_ignores_duplicates_and_non_web_links
    html = <<~HTML
      <div id="rso">
        <div class="MjjYud"><a href="https://example.net/"><h3>News module</h3></a></div>
        <div class="g"><a href="/url?q=https%3A%2F%2Fexample.com%2Fpage"><h3>First      result</h3></a></div>
        <div class="g"><a href="https://example.com/page"><h3>Duplicate</h3></a></div>
        <div class="g"><a href="javascript:void(0)"><h3>Invalid</h3></a></div>
        <div class="g"><a href="https://example.org/"><h3>Second result</h3></a></div>
      </div>
    HTML
    results = @parser.call(html)
    assert_equal [ "First result", "Second result" ], results.map(&:title)
    assert_equal [ "https://example.com/page", "https://example.org/" ], results.map(&:link)
    assert_nil results.first.snippet
  end

  def test_limits_organic_results_to_ten
    cards = (1..11).map { |rank| %(<div class="g"><a href="https://example.com/#{rank}"><h3>Result #{rank}</h3></a></div>) }
    results = @parser.call(%(<div id="rso">#{cards.join}</div>))
    assert_equal 10, results.size
    assert_equal "Result 10", results.last.title
  end

  def test_recognizes_genuine_zero_results
    assert_empty @parser.call('<div id="topstuff">Your search did not match any documents.</div>')
    assert_empty @parser.call('<div id="topstuff"></div><div id="search">No results found.</div>')
  end

  def test_a_result_that_mentions_a_challenge_is_still_a_result
    html = <<~HTML
      <div id="rso"><div class="g"><a href="https://example.com/">
        <h3>Our systems have detected unusual traffic</h3>
      </a></div></div>
    HTML
    assert_equal 1, @parser.call(html).length
  end

  def test_distinguishes_a_google_challenge_from_unknown_markup
    challenge = assert_raises(GoogleSearch::Error) { @parser.call('<form id="captcha-form"></form>') }
    assert_equal :upstream_challenge, challenge.code

    unknown = assert_raises(GoogleSearch::Error) { @parser.call('<div id="rso"></div>') }
    assert_equal :unknown_layout, unknown.code
  end

  def test_rejects_markup_deeper_than_nokogiri_supports
    error = assert_raises(GoogleSearch::Error) { @parser.call("<div>" * 600 + "</div>" * 600) }
    assert_equal :unknown_layout, error.code
  end

  private

  # Trimmed captures of real result pages: the renderer's output, reduced to
  # the query box, result stats, #rso and pagination.
  def live_fixture(name)
    File.read(File.expand_path("../fixtures/google_search/live/#{name}", __dir__), encoding: "UTF-8")
  end
end
