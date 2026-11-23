require "minitest/autorun"
require_relative "../../app/services/google_search/error"
require_relative "../../app/services/google_search/parser"

class GoogleSearchParserTest < Minitest::Test
  def setup
    @parser = GoogleSearch::Parser.new
  end

  def test_example_results_keep_source_order
    html = File.read(File.expand_path("../fixtures/google_search/example.html", __dir__))
    results = @parser.call(html)
    assert_equal [ 1, 2, 3, 4 ], results.map(&:position)
    assert_equal "Ruby on Rails Guides", results.first.title
    assert_equal "https://guides.rubyonrails.org/", results.first.link
    assert_match "Documentation for Ruby on Rails", results.first.snippet
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
end
