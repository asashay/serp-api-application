require_relative "../test_helper"
require "socket"

class PageCaptureRendererTest < ActiveSupport::TestCase
  URL = "https://www.google.com/search?q=rails&hl=en".freeze

  test "reads the render deadline with the renderer's rules" do
    assert_equal 240.0, PageCapture::Renderer.deadline("240")
    assert_equal 150.5, PageCapture::Renderer.deadline("150.5")
    [ nil, "", "10", "60", "110", "-5", "150s", "inf", "nan", "Infinity" ].each do |value|
      assert_equal 110.0, PageCapture::Renderer.deadline(value), value.inspect
    end
  end

  test "posts the URL and location and returns the captured page with its timing log" do
    request = nil
    log = "render outcome=ok total_ms=9 é#{'x' * 3000}"
    renderer = with_renderer(200, "<html>café</html>", { "X-Page-Url" => URL, "X-Render-Log" => log }) do |seen|
      request = seen
    end

    final_url, html = renderer.call(URL, location: "Austin, Texas, United States")
    assert_equal URL, final_url
    assert_equal "<html>café</html>", html
    assert_equal Encoding::UTF_8, html.encoding
    assert_match %r{\APOST /render }, request
    assert_equal({ "url" => URL, "location" => "Austin, Texas, United States" }, JSON.parse(request.split("\r\n\r\n", 2).last))
    assert_equal PageCapture::Renderer::LOG_LIMIT, renderer.log.length
    assert renderer.log.ascii_only?
  end

  test "rejects a page that is off site, empty, not UTF-8 or over the limit" do
    {
      "off site" => [ "<html></html>", "https://evil.example/search" ],
      "no final URL" => [ "<html></html>", nil ],
      "empty" => [ "", URL ],
      "not UTF-8" => [ "\xff\xfe".b, URL ],
      "over the limit" => [ "a" * (PageCapture::Renderer::LIMIT + 1), URL ]
    }.each do |name, (body, final_url)|
      renderer = with_renderer(200, body, { "X-Page-Url" => final_url }.compact)
      assert_error "upstream_unavailable", 503, renderer, name
    end
  end

  test "maps the renderer's statuses to API errors" do
    assert_error "upstream_challenge", 502, with_renderer(429, "")
    assert_error "upstream_timeout", 504, with_renderer(504, "")
    assert_error "upstream_unavailable", 503, with_renderer(503, "")
    assert_error "upstream_unavailable", 503, with_renderer(400, "")
  end

  test "reports a renderer that is down or too slow" do
    port = TCPServer.open("127.0.0.1", 0).then { |server| server.addr[1].tap { server.close } }
    assert_error "upstream_unavailable", 503, PageCapture::Renderer.new(endpoint: URI("http://127.0.0.1:#{port}"))
    assert_error "upstream_timeout", 504, with_renderer(200, "", delay: 1, read_timeout: 0.2)
  end

  private

  # A one-request stand-in for renderer/server.py on a free loopback port.
  def with_renderer(status, body, headers = {}, delay: 0, read_timeout: 5)
    server = TCPServer.open("127.0.0.1", 0)
    @threads = (@threads || []) << Thread.new do
      client = server.accept
      head = +""
      head << client.gets until head.end_with?("\r\n\r\n")
      length = head[/^content-length: (\d+)/i, 1].to_i
      yield head + client.read(length) if block_given?
      sleep delay
      lines = headers.map { |name, value| "#{name}: #{value.b}\r\n" }.join
      client.write("HTTP/1.1 #{status} X\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n#{lines}\r\n".b + body.b)
      client.close
    rescue IOError, SystemCallError
      nil
    ensure
      server.close
    end
    PageCapture::Renderer.new(endpoint: URI("http://127.0.0.1:#{server.addr[1]}"), read_timeout: read_timeout)
  end

  def assert_error(code, status, renderer, message = nil)
    error = assert_raises(PageCapture::Renderer::Error, message) { renderer.call(URL) }
    assert_equal [ code, status ], [ error.code, error.status ], message
  end

  def teardown
    @threads&.each { |thread| thread.join(2) }
  end
end
