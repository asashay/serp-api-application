require_relative "../test_helper"

class PageCaptureRendererTest < ActiveSupport::TestCase
  test "reads the render deadline with the renderer's rules" do
    assert_equal 240.0, PageCapture::Renderer.deadline("240")
    assert_equal 150.5, PageCapture::Renderer.deadline("150.5")
    [ nil, "", "10", "60", "110", "-5", "150s", "inf", "nan", "Infinity" ].each do |value|
      assert_equal 110.0, PageCapture::Renderer.deadline(value), value.inspect
    end
  end
end
