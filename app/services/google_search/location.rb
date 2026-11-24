require "base64"
require "json"

module GoogleSearch
  # The places a search can come from. config/locations.json is shared with the
  # Worker (validation before quota) and the renderer (exit IP targeting).
  module Location
    # Google's uule parameter: "w+CAIQICI", a character for the length of the
    # canonical name (its index in the base64 alphabet), then the name in base64.
    UULE_KEYS = [ *"A".."Z", *"a".."z", *"0".."9", "-", "_" ].freeze

    Entry = Data.define(:name, :gl, :canonical) do
      # Tells Google where the search comes from, whatever the exit IP's
      # geolocation says; the IP is in the same city as a second signal.
      def uule
        "w+CAIQICI#{UULE_KEYS.fetch(canonical.bytesize)}#{Base64.strict_encode64(canonical)}"
      end
    end
    PATH = File.expand_path("../../../config/locations.json", __dir__)
    ALL = JSON.parse(File.read(PATH)).map do |entry|
      Entry.new(name: entry.fetch("name"), gl: entry.fetch("gl"), canonical: entry.fetch("canonical"))
    end.freeze

    def self.find(name)
      ALL.find { |entry| entry.name == name }
    end

    def self.names
      ALL.map(&:name)
    end
  end
end
