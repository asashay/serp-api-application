require_relative "../test_helper"

class PageCaptureRendererTest < ActiveSupport::TestCase
  test "reads the render deadline with the renderer's rules" do
    assert_equal 120.0, PageCapture::Renderer.deadline("120")
    assert_equal 75.5, PageCapture::Renderer.deadline("75.5")
    [ nil, "", "10", "45", "-5", "75s", "inf", "nan", "Infinity" ].each do |value|
      assert_equal 60.0, PageCapture::Renderer.deadline(value), value.inspect
    end
  end
end
