require_relative "../test_helper"

class SearchTest < ActionDispatch::IntegrationTest
  test "serves a public fixture using the live API shape locally" do
    get "/search.json", params: { q: "Ruby on Rails guides" }
    assert_response :success
    assert_equal "*", response.headers["Access-Control-Allow-Origin"]
    assert_includes response.headers["Cache-Control"], "no-store"
    assert_equal "fixture", response.parsed_body["source"]
    assert_equal "Ruby on Rails guides", response.parsed_body["query"]
    assert_equal response.headers["X-Request-Id"], response.parsed_body["request_id"]
    assert_equal 1, response.parsed_body["organic_results"].first["position"]
  end

  test "rejects duplicate, absent, and oversized queries" do
    [ "", "?q=a&q=b", "?q[]=a", "?q=#{'a' * 201}" ].each do |query|
      get "/search.json#{query}"
      assert_response :bad_request
      assert_equal "invalid_query", response.parsed_body.dig("error", "code")
    end
  end

  test "labels and exposes the saved example independently" do
    get "/example.json"
    assert_response :success
    assert_equal "fixture", response.parsed_body["source"]
    assert_equal "Ruby on Rails guides", response.parsed_body["query"]
  end

  test "never substitutes the saved result for an arbitrary local query" do
    get "/search.json", params: { q: "coffee & tea" }
    assert_response :unprocessable_entity
    assert_equal "fixture_query_unavailable", response.parsed_body.dig("error", "code")
  end

  test "does not accept internal HTML on the local app" do
    post "/internal/search", params: { query: "Rails", html: "<h3>Test</h3>" }, as: :json
    assert_response :not_found
  end
end
