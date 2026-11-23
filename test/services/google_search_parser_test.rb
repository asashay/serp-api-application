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
        <a href="/url?q=https%3A%2F%2Fexample.com%2Fpage"><h3>First      result</h3></a>
        <a href="https://example.com/page"><h3>Duplicate</h3></a>
        <a href="javascript:void(0)"><h3>Invalid</h3></a>
        <a href="https://example.org/"><h3>Second result</h3></a>
      </div>
    HTML
    results = @parser.call(html)
    assert_equal [ "First result", "Second result" ], results.map(&:title)
    assert_equal [ "https://example.com/page", "https://example.org/" ], results.map(&:link)
    assert_nil results.first.snippet
  end

  def test_limits_organic_results_to_ten
    cards = (1..11).map { |rank| %(<a href="https://example.com/#{rank}"><h3>Result #{rank}</h3></a>) }
    results = @parser.call(%(<div id="rso">#{cards.join}</div>))
    assert_equal 10, results.size
    assert_equal "Result 10", results.last.title
  end

  def test_recognizes_genuine_zero_results
    assert_empty @parser.call('<div id="topstuff">Your search did not match any documents.</div>')
  end

  def test_distinguishes_a_google_challenge_from_unknown_markup
    challenge = assert_raises(GoogleSearch::Error) { @parser.call('<form id="captcha-form"></form>') }
    assert_equal :upstream_challenge, challenge.code

    unknown = assert_raises(GoogleSearch::Error) { @parser.call('<div id="rso"></div>') }
    assert_equal :unknown_layout, unknown.code
  end
end
