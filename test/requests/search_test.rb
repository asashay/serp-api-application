require_relative "../test_helper"

class SearchTest < ActionDispatch::IntegrationTest
  test "serves the saved page using the public API shape locally" do
    get "/search.json", params: { q: "/" }
    assert_response :success
    assert_equal "*", response.headers["Access-Control-Allow-Origin"]
    assert_includes response.headers["Cache-Control"], "no-store"
    assert_equal "fixture", response.parsed_body["source"]
    assert_equal "https://lingorep.com/", response.parsed_body["url"]
    assert_equal response.headers["X-Request-Id"], response.parsed_body["request_id"]
    assert_equal 1, response.parsed_body["headings"].find { |heading| heading.fetch("level") == 1 }.fetch("level")
  end

  test "rejects duplicate, absent, oversized, and off-site inputs" do
    [ "", "?q=a&q=b", "?q[]=a", "?q=#{'a' * 201}", "?q=%2F%2Felsewhere.example", "?q=a%2F..%2Fb" ].each do |query|
      get "/search.json#{query}"
      assert_response :bad_request
      assert_equal "invalid_query", response.parsed_body.dig("error", "code")
    end
  end

  test "encodes nested path segments and keeps the destination fixed" do
    assert_equal "https://lingorep.com/", PageCapture::Path.url("/")
    assert_equal "https://lingorep.com/pricing", PageCapture::Path.url("pricing")
    assert_equal "https://lingorep.com/blog/coffee%20%26%20tea/%C3%A9", PageCapture::Path.url("/blog/coffee & tea/é")
    assert_nil PageCapture::Path.url("https://elsewhere.example/")
    assert_nil PageCapture::Path.url("/%2e%2e")
  end

  test "labels and exposes the saved example independently" do
    get "/example.json"
    assert_response :success
    assert_equal "fixture", response.parsed_body["source"]
    assert_equal "https://lingorep.com/", response.parsed_body["url"]
  end

  test "never substitutes the saved result for a different local path" do
    get "/search.json", params: { q: "pricing" }
    assert_response :unprocessable_entity
    assert_equal "fixture_query_unavailable", response.parsed_body.dig("error", "code")
  end

  test "keeps the capture route internal" do
    post "/internal/capture", params: { path: "/" }, as: :json
    assert_response :not_found
  end
end
