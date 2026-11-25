import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "renderer"))

from timings import Timings


class Clock:
    def __init__(self):
        self.now = 100.0

    def __call__(self):
        return self.now

    def advance(self, seconds):
        self.now += seconds


class TimingsTest(unittest.TestCase):
    def test_times_each_step_and_the_total(self):
        clock = Clock()
        timings = Timings(clock)
        clock.advance(0.05)
        timings.begin("load")
        clock.advance(4.2)
        timings.begin("links")
        clock.advance(1.5)
        timings.finish()
        timings.note(google_status=200, links_resolved=7)
        clock.advance(0.01)

        self.assertEqual(timings.line("ok"),
                         "outcome=ok load_ms=4200 links_ms=1500 google_status=200 links_resolved=7 total_ms=5760")

    def test_names_and_times_an_unfinished_step(self):
        clock = Clock()
        timings = Timings(clock)
        timings.begin("load")
        clock.advance(27)

        self.assertEqual(timings.line("timeout"), "outcome=timeout stopped_in=load load_ms=27000 total_ms=27000")


if __name__ == "__main__":
    unittest.main()
