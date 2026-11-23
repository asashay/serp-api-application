require_relative "../test_helper"

class PlaygroundTest < ActionDispatch::IntegrationTest
  test "shows the opening query and its isolated HTML preview" do
    get "/"
    assert_response :success
    assert_select "html[lang='en']"
    assert_select "link[rel='stylesheet']"
    assert_select "script[type='importmap']"
    assert_select "h1", "Google Search API"
    assert_select "input#query[value='Ruby on Rails guides']"
    assert_select "iframe[sandbox]" do |frames|
      preview = Nokogiri::HTML5(frames.first["srcdoc"])
      assert_equal "Ruby on Rails Guides", preview.at_css("h3").text
    end
  end

  test "returns corresponding HTML and JSON from the fixture" do
    get "/playground/search", params: { q: "Ruby on Rails guides" }
    assert_response :success
    payload = response.parsed_body
    preview = Nokogiri::HTML5(payload.fetch("preview_html"))
    assert_equal payload.dig("response", "organic_results", 0, "title"), preview.at_css("h3").text
  end

  test "strips active content and network attributes from the preview" do
    html = <<~HTML
      <main id="search">
        <h3 onclick="doSomething()">Visible result</h3>
        <a href="https://other.example/">Link label</a>
        <img src="https://other.example/image">
        <iframe src="https://other.example/frame"></iframe>
        <script>window.parent.alert()</script>
        <style>@import "https://other.example/external";</style>
        <form action="https://other.example/post"><button>Submit</button></form>
      </main>
    HTML
    preview = Nokogiri::HTML5(GoogleSearch::Preview.new.call(html))
    assert_equal "Visible result", preview.at_css("h3").text
    assert_equal "Link label", preview.at_css("a").text
    assert_empty preview.css("script, iframe, img, form, [href], [src], [onclick]")
    refute_includes preview.to_html, "other.example"
    assert_includes preview.at_css("meta[http-equiv='Content-Security-Policy']")["content"], "default-src 'none'"
  end
end
