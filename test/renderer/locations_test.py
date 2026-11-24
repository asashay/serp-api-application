import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "renderer"))
from locations import TARGETING, targeting


class TargetingTest(unittest.TestCase):
    def test_maps_only_shared_location_names(self):
        self.assertEqual(2, len(TARGETING))
        self.assertEqual((True, "cr.us;city.austin"), targeting("Austin, Texas, United States"))
        self.assertEqual((True, "cr.fr;city.paris"), targeting("Paris, Ile-de-France, France"))
        self.assertEqual((False, None), targeting("Barcelona, Catalonia, Spain"))
        self.assertEqual((True, None), targeting(None))
        for name in ("", "Austin", "cr.us;city.austin", 7, ["Austin, Texas, United States"]):
            self.assertEqual((False, None), targeting(name), name)


if __name__ == "__main__":
    unittest.main()
