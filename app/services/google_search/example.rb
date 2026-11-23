module GoogleSearch
  module Example
    QUERY = "Ruby on Rails guides"
    PATH = Rails.root.join("test/fixtures/google_search/example.html")

    def self.html
      File.read(PATH, encoding: "UTF-8")
    end
  end
end
