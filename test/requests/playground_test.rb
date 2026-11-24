require_relative "../test_helper"

class PlaygroundTest < ActionDispatch::IntegrationTest
  test "shows the opening query and the saved API response" do
    get "/"
    assert_response :success
    assert_select "html[lang='en']"
    assert_select "link[rel='stylesheet']"
    assert_select "script[type='importmap']"
    assert_select "h1", "Google Search API"
    assert_select "input#query[value='best matcha bar']"
    assert_select "iframe.page-frame[sandbox=''][referrerpolicy='no-referrer']", count: 1 do |frame|
      page = Nokogiri::HTML5(frame.first["srcdoc"])
      assert_equal 7, page.css("#rso h3").size
      assert_empty page.css("[href], script")
      assert page.at_css('meta[http-equiv="Content-Security-Policy"]')
    end
    assert_select "pre code" do |code|
      payload = JSON.parse(code.first.text)
      assert_equal "best matcha bar", payload.fetch("query")
      assert_equal 0, payload.fetch("elapsed_ms")
      assert_equal 0.0, payload.dig("search_metadata", "total_time_taken")
      assert_equal "The 9 Best Matcha in Houston | MyBestHouston", payload.fetch("organic_results").first.fetch("title")
      assert_equal "https://mybesthouston.com/matcha/", payload.fetch("organic_results").first.fetch("link")
    end
  end

  test "returns the public API response plus a link-free page preview" do
    get "/playground/search", params: { q: "best matcha bar" }
    assert_response :success
    playground = stable_shape(response.parsed_body)
    preview = Nokogiri::HTML5(playground.delete("preview_html"))

    get "/search.json", params: { q: "best matcha bar" }
    assert_equal stable_shape(response.parsed_body), playground
    refute response.parsed_body.key?("preview_html")
    assert_equal 7, preview.css("#rso h3").size
    assert_empty preview.css("[href], script")
  end

  private

  # Drops the values that differ on every request.
  def stable_shape(body)
    body.except("request_id", "elapsed_ms").merge(
      "search_metadata" => body.fetch("search_metadata").except("id", "created_at", "processed_at", "total_time_taken")
    )
  end
end
