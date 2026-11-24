import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "renderer"))
from consent import REMOVE, remove_consent


class Page:
    def __init__(self, result=None, error=None):
        self.result = result
        self.error = error
        self.scripts = []

    async def evaluate(self, script):
        self.scripts.append(script)
        if self.error:
            raise self.error
        return self.result


class RemoveConsentTest(unittest.IsolatedAsyncioTestCase):
    async def test_reports_a_removed_dialog(self):
        page = Page(result=True)

        with self.assertLogs("renderer", "INFO"):
            self.assertTrue(await remove_consent(page))
        self.assertEqual([REMOVE], page.scripts)

    async def test_leaves_pages_without_a_dialog_alone(self):
        self.assertFalse(await remove_consent(Page(result=False)))

    async def test_keeps_the_capture_when_the_script_fails(self):
        with self.assertLogs("renderer", "WARNING") as logs:
            self.assertFalse(await remove_consent(Page(error=RuntimeError("page closed"))))
        self.assertIn("RuntimeError", logs.output[0])

    def test_targets_only_the_reject_all_dialog(self):
        self.assertIn("reject all", REMOVE)
        self.assertIn('[aria-modal="true"]', REMOVE)


if __name__ == "__main__":
    unittest.main()
