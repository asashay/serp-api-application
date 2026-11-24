require_relative "../test_helper"

class PlaygroundTest < ActionDispatch::IntegrationTest
  test "shows the opening query and the saved API response" do
    get "/"
    assert_response :success
    assert_select "html[lang='en']"
    assert_select "link[rel='stylesheet']"
    assert_select "script[type='importmap']"
    assert_select "h1", "Google Search API"
    assert_select "input#query[value='/']"
    assert_select "iframe", count: 0
    assert_select "pre code" do |code|
      payload = JSON.parse(code.first.text)
      assert_equal "https://lingorep.com/", payload.fetch("url")
      assert_includes payload.fetch("headings").map { |heading| heading.fetch("text") },
        "Improve your spoken English with every conversation."
    end
  end

  test "returns the same response shape as the public API" do
    get "/playground/search", params: { q: "/" }
    assert_response :success
    playground = response.parsed_body.except("request_id")

    get "/search.json", params: { q: "/" }
    assert_equal response.parsed_body.except("request_id"), playground
    refute playground.key?("preview_html")
  end

  test "extracts the title, description and headings in document order" do
    html = <<~HTML
      <html><head><title>  Page   title </title><meta name="description" content="About the page"></head>
      <body>
        <h2>First</h2>
        <section><h1>Second <a href="/x">linked</a></h1><h3>   </h3></section>
        <h6>Third</h6>
      </body></html>
    HTML
    payload = PageCapture::Document.new(html).response(url: "https://lingorep.com/", source: "lingorep",
      request_id: "id", elapsed_ms: 5)
    assert_equal "Page title", payload[:title]
    assert_equal "About the page", payload[:description]
    assert_equal [ { level: 2, text: "First" }, { level: 1, text: "Second linked" }, { level: 6, text: "Third" } ],
      payload[:headings]
  end
end
