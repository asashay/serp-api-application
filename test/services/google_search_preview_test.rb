require "minitest/autorun"
require_relative "../../app/services/google_search/preview"

class GoogleSearchPreviewTest < Minitest::Test
  def test_keeps_the_look_but_removes_links_scripts_and_outside_resources
    html = <<~HTML
      <!doctype html><html><head>
        <base href="https://evil.example/"><meta http-equiv="refresh" content="0;url=https://evil.example/">
        <link rel="stylesheet" href="https://evil.example/a.css">
        <style>@import url(https://evil.example/b.css); h3 { color: #1a0dab; }</style>
        <script>alert(1)</script>
      </head><body onload="alert(2)">
        <!-- {"tracking": "data"} -->
        <div id="rso" class="card" style="margin: 4px" data-ved="x" jsaction="click:y">
          <a href="https://example.com/" ping="https://evil.example/p" target="_blank"><h3>Title</h3></a>
          <a href="javascript:alert(3)">Script link</a>
          <img src="data:image/png;base64,AAAA" alt="Favicon">
          <img src="https://evil.example/pixel.gif" srcset="https://evil.example/2x.gif 2x">
          <svg viewBox="0 0 24 24"><path d="M0 0h24v24H0z" fill="#fff"/></svg>
          <form action="https://evil.example/f"><textarea name="q">coffee</textarea><button formaction="https://evil.example/">Go</button></form>
          <iframe src="https://evil.example/"></iframe><object data="https://evil.example/o"></object>
          <div style="color: red" onclick="alert(4)" onmouseover="alert(5)">Text</div>
        </div>
      </body></html>
    HTML
    preview = GoogleSearch::Preview.new(html).call
    page = Nokogiri::HTML5(preview)

    assert_empty page.css("script, iframe, object, embed, base, link, noscript")
    assert_empty page.xpath("//@*[starts-with(name(), 'on')]")
    %w[href ping target srcset action formaction name data-ved jsaction].each do |attribute|
      assert_empty page.css("[#{attribute}]"), attribute
    end
    assert_equal [ "data:image/png;base64,AAAA" ], page.css("img[src]").map { |img| img["src"] }
    assert_empty page.xpath("//comment()")
    refute_includes preview, "evil.example"

    assert_equal "Title", page.at_css("a h3").text
    assert_equal "card", page.at_css("#rso")["class"]
    assert_equal "margin: 4px", page.at_css("#rso")["style"]
    assert_equal "0 0 24 24", page.at_css("svg")["viewbox"] || page.at_css("svg")["viewBox"]
    assert_includes page.css("style").map(&:text).join, "h3 { color: #1a0dab; }"
    assert_equal "coffee", page.at_css("textarea").text

    csp = page.at_css('meta[http-equiv="Content-Security-Policy"]')["content"]
    assert_includes csp, "default-src 'none'"
    assert_includes csp, "img-src data:"
    assert_equal [ csp ], page.css("meta[http-equiv]").map { |meta| meta["content"] }
    assert_match(/a, button.*pointer-events: none !important/m, page.at_css("head style").text)
  end

  def test_builds_a_head_for_a_fragment_and_keeps_large_pages
    preview = GoogleSearch::Preview.new("<div>Fragment</div>").call
    assert_includes preview, "Content-Security-Policy"
    assert_includes preview, "Fragment"

    large = "<div>#{'a' * (3 * 1024 * 1024)}</div>"
    assert_operator GoogleSearch::Preview.new(large).call.bytesize, :>, 3 * 1024 * 1024
  end
end
