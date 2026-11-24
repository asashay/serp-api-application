require_relative "../test_helper"

class SearchTest < ActionDispatch::IntegrationTest
  test "serves a public fixture using the live API shape locally" do
    get "/search.json", params: { q: "best matcha bar" }
    assert_response :success
    assert_equal "*", response.headers["Access-Control-Allow-Origin"]
    assert_includes response.headers["Cache-Control"], "no-store"
    assert_equal "fixture", response.parsed_body["source"]
    assert_equal "best matcha bar", response.parsed_body["query"]
    assert_equal response.headers["X-Request-Id"], response.parsed_body["request_id"]
    assert_equal 1, response.parsed_body["organic_results"].first["position"]
    assert_equal "https://mybesthouston.com/matcha/", response.parsed_body["organic_results"].first["link"]
  end

  test "describes the search alongside the results" do
    get "/search.json", params: { q: "best matcha bar" }
    body = response.parsed_body

    metadata = body.fetch("search_metadata")
    assert_equal body["request_id"], metadata["id"]
    assert_equal "Success", metadata["status"]
    assert_equal "https://www.google.com/search?q=best+matcha+bar&hl=en&gl=us&uule=w%2BCAIQICIaQXVzdGluLFRleGFzLFVuaXRlZCBTdGF0ZXM%3D", metadata["google_url"]
    assert_in_delta body["elapsed_ms"] / 1000.0, metadata["total_time_taken"], 0.001
    assert_in_delta metadata["total_time_taken"],
      Time.iso8601(metadata["processed_at"]) - Time.iso8601(metadata["created_at"]), 0.002
    assert_equal({ "engine" => "google", "q" => "best matcha bar", "location_requested" => "Austin, Texas, United States",
      "location_used" => "Austin, Texas, United States", "google_domain" => "google.com", "hl" => "en", "gl" => "us",
      "device" => "desktop" }, body["search_parameters"])
    assert_equal "https://mybesthouston.com › matcha", body["organic_results"].first["displayed_link"]
    assert_equal({ "query_displayed" => "best matcha bar", "total_results" => 10, "time_taken_displayed" => 0.4 },
      body["search_information"])
    assert_not body.key?("pagination"), "the saved example has a single page of results"
  end

  test "rejects duplicate, absent, and oversized queries" do
    [ "", "?q=a&q=b", "?q[]=a", "?q=#{'a' * 201}", "?q=a%2F..%2Fb&foo=bar" ].each do |query|
      get "/search.json#{query}"
      assert_response :bad_request
      assert_equal "invalid_query", response.parsed_body.dig("error", "code")
    end
  end

  test "builds an encoded Google search URL without changing the destination" do
    assert_equal "https://www.google.com/search?q=coffee+%26+tea&hl=en", GoogleSearch::Query.url("coffee & tea")
    assert_equal "https://www.google.com/search?q=https%3A%2F%2Fexample.com%2F&hl=en",
      GoogleSearch::Query.url("https://example.com/")
    assert_nil GoogleSearch::Query.url("a" * 201)
  end

  test "labels and exposes the saved example independently" do
    get "/example.json"
    assert_response :success
    assert_equal "fixture", response.parsed_body["source"]
    assert_equal "best matcha bar", response.parsed_body["query"]
  end

  test "never substitutes the saved result for an arbitrary local query" do
    get "/search.json", params: { q: "coffee & tea" }
    assert_response :unprocessable_entity
    assert_equal "fixture_query_unavailable", response.parsed_body.dig("error", "code")
  end

  test "renders an arbitrary query through the local renderer when local live search is on" do
    url = GoogleSearch::Query.url("coffee & tea")
    renderer = Minitest::Mock.new
    renderer.expect(:call, [ url, GoogleSearch::Example.html ], [ url ], location: nil)
    previous = ENV["LOCAL_LIVE_SEARCH"]
    begin
      ENV["LOCAL_LIVE_SEARCH"] = "1"
      PageCapture::Renderer.stub(:new, -> { renderer }) do
        get "/search.json", params: { q: "coffee & tea" }
      end
    ensure
      ENV["LOCAL_LIVE_SEARCH"] = previous
    end

    assert_response :success
    assert_equal "google", response.parsed_body["source"]
    assert_equal "coffee & tea", response.parsed_body["query"]
    renderer.verify
  end

  test "keeps the capture route internal" do
    post "/internal/capture", params: { query: "Rails" }, as: :json
    assert_response :not_found
  end

  test "renders Google and parses organic results in the internal capture" do
    query = GoogleSearch::Example::QUERY
    url = GoogleSearch::Query.url(query)
    renderer = Minitest::Mock.new
    renderer.expect(:call, [ url, GoogleSearch::Example.html ], [ url ], location: nil)
    previous_container = ENV["CLOUDFLARE_CONTAINER"]
    begin
      ENV["CLOUDFLARE_CONTAINER"] = "1"
      PageCapture::Renderer.stub(:new, -> { renderer }) do
        post "/internal/capture", params: { query: query, elapsed_ms: 12 }, as: :json
      end
    ensure
      ENV["CLOUDFLARE_CONTAINER"] = previous_container
    end

    assert_response :success
    assert_not response.parsed_body.key?("preview_html")
    assert_equal "1", response.headers["X-Search-Response"]
    assert_equal "google", response.parsed_body["source"]
    assert_equal query, response.parsed_body["query"]
    assert_equal 5, response.parsed_body["organic_results"].length
    assert_operator response.parsed_body["elapsed_ms"], :>=, 12
    renderer.verify
  end

  test "adds the page preview to an internal capture only when the Worker asks" do
    query = GoogleSearch::Example::QUERY
    url = GoogleSearch::Query.url(query)
    previous_container = ENV["CLOUDFLARE_CONTAINER"]
    previews = [ true, false ].map do |preview|
      renderer = Minitest::Mock.new
      renderer.expect(:call, [ url, GoogleSearch::Example.html ], [ url ], location: nil)
      begin
        ENV["CLOUDFLARE_CONTAINER"] = "1"
        PageCapture::Renderer.stub(:new, -> { renderer }) do
          post "/internal/capture", params: { query: query, preview: preview }, as: :json
        end
      ensure
        ENV["CLOUDFLARE_CONTAINER"] = previous_container
      end
      assert_response :success
      response.parsed_body["preview_html"]
    end

    assert_includes previews.first, "Content-Security-Policy"
    assert_nil previews.last
  end

  test "accepts one optional location from the shared list" do
    austin = GoogleSearch::Location.find("Austin, Texas, United States")
    assert_equal "us", austin.gl
    assert_equal "w+CAIQICIaQXVzdGluLFRleGFzLFVuaXRlZCBTdGF0ZXM=", austin.uule
    assert_equal 2, GoogleSearch::Location.names.size
    assert_equal [ "matcha", "Austin, Texas, United States" ],
      GoogleSearch::Query.parse("q=matcha&location=Austin%2C+Texas%2C+United+States")
    assert_equal [ "matcha", nil ], GoogleSearch::Query.parse("q=matcha")
    assert_nil GoogleSearch::Query.parse("q=matcha&location=a&location=b")
    assert_nil GoogleSearch::Query.parse("location=Paris")
    assert_equal "https://www.google.com/search?q=matcha&hl=en&gl=fr&uule=w%2BCAIQICIaUGFyaXMsSWxlLWRlLUZyYW5jZSxGcmFuY2U%3D",
      GoogleSearch::Query.url("matcha", location: GoogleSearch::Location.find("Paris, Ile-de-France, France"))
  end

  test "rejects an unknown location and keeps the fixture to its own query" do
    [ "Mars", "", "cr.us;city.austin" ].each do |location|
      get "/search.json", params: { q: "best matcha bar", location: location }
      assert_response :bad_request
      assert_equal "invalid_location", response.parsed_body.dig("error", "code")
    end

    get "/search.json", params: { q: "best matcha bar", location: "Austin, Texas, United States" }
    assert_response :success
    assert_equal "Austin, Texas, United States", response.parsed_body.dig("search_parameters", "location_used")

    get "/search.json", params: { q: "best matcha bar", location: "Paris, Ile-de-France, France" }
    assert_response :unprocessable_entity
    assert_equal "fixture_query_unavailable", response.parsed_body.dig("error", "code")
  end

  test "searches from a location through the local renderer" do
    austin = GoogleSearch::Location.find("Austin, Texas, United States")
    url = GoogleSearch::Query.url("matcha", location: austin)
    renderer = Minitest::Mock.new
    renderer.expect(:call, [ url, GoogleSearch::Example.html ], [ url ], location: austin.name)
    previous = ENV["LOCAL_LIVE_SEARCH"]
    begin
      ENV["LOCAL_LIVE_SEARCH"] = "1"
      PageCapture::Renderer.stub(:new, -> { renderer }) do
        get "/search.json", params: { q: "matcha", location: austin.name }
      end
    ensure
      ENV["LOCAL_LIVE_SEARCH"] = previous
    end

    assert_response :success
    assert_equal({ "engine" => "google", "q" => "matcha", "location_requested" => austin.name,
      "location_used" => austin.name, "google_domain" => "google.com", "hl" => "en", "gl" => "us",
      "device" => "desktop" }, response.parsed_body["search_parameters"])
    assert_equal "https://www.google.com/search?q=matcha&hl=en&gl=us&uule=w%2BCAIQICIaQXVzdGluLFRleGFzLFVuaXRlZCBTdGF0ZXM%3D",
      response.parsed_body.dig("search_metadata", "google_url")
    renderer.verify
  end

  test "passes the Worker's location to the renderer and rejects unknown ones" do
    paris = GoogleSearch::Location.find("Paris, Ile-de-France, France")
    url = GoogleSearch::Query.url("matcha", location: paris)
    renderer = Minitest::Mock.new
    renderer.expect(:call, [ url, GoogleSearch::Example.html ], [ url ], location: paris.name)
    previous_container = ENV["CLOUDFLARE_CONTAINER"]
    begin
      ENV["CLOUDFLARE_CONTAINER"] = "1"
      PageCapture::Renderer.stub(:new, -> { renderer }) do
        post "/internal/capture", params: { query: "matcha", location: paris.name }, as: :json
        assert_response :success
        assert_equal "fr", response.parsed_body.dig("search_parameters", "gl")

        post "/internal/capture", params: { query: "matcha", location: "Mars" }, as: :json
        assert_response :bad_request
        assert_equal "invalid_location", response.parsed_body.dig("error", "code")
      end
    ensure
      ENV["CLOUDFLARE_CONTAINER"] = previous_container
    end
    renderer.verify
  end
end
