"""The render flow and its timing logs, with a fake browser and no network.

aiohttp and invisible-playwright are installed only in the container image,
so minimal stand-ins are used when they are missing.
"""
import asyncio
import sys
import types
import unittest
from unittest import mock
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "renderer"))


def stand_in(name, **attributes):
    module = types.ModuleType(name)
    module.__dict__.update(attributes)
    sys.modules[name] = module
    return module


try:
    import aiohttp  # noqa: F401
except ImportError:
    class Response:
        def __init__(self, status=200, body=None, headers=None, **_options):
            self.status, self.body, self.headers = status, body, headers or {}

    stand_in("aiohttp", web=stand_in("aiohttp.web", Response=Response))

try:
    import invisible_playwright  # noqa: F401
except ImportError:
    class BrowserError(Exception):
        pass

    stand_in("invisible_playwright")
    stand_in("invisible_playwright.async_api", InvisiblePlaywright=object)
    stand_in("invisible_playwright._pw")
    stand_in("invisible_playwright._pw.async_api", Error=BrowserError,
             TimeoutError=type("TimeoutError", (BrowserError,), {}))

import attempts  # noqa: E402
import links  # noqa: E402
import server  # noqa: E402

URL = "https://www.google.com/search?q=matcha&hl=en"


class GoogleResponse:
    def __init__(self, status):
        self.status = status
        self.ok = status < 400


class Locator:
    def __init__(self, page):
        self.page = page

    async def count(self):
        # A late challenge is not there when the HTML is parsed, only later.
        self.page.challenge_checks += 1
        return int(getattr(self.page.load, "late_challenge", False) and self.page.challenge_checks > 1)


class Page:
    def __init__(self, load):
        self.load = load
        self.url = URL
        self.waits = []
        self.challenge_checks = 0

    async def goto(self, url, wait_until, timeout):
        self.waits.append((wait_until, timeout))
        return self.load()

    async def wait_for_load_state(self, state, timeout):
        self.waits.append((state, timeout))
        if getattr(self.load, "images_stall", False):
            raise server.BrowserTimeout("Timeout exceeded")

    def locator(self, _selector):
        return Locator(self)

    async def evaluate(self, script, *_args):
        if script == server.CAPTURE:
            if getattr(self.load, "capture_stalls", False):
                raise server.BrowserTimeout("Timeout exceeded")
            return {"html": "<html><div id=rso></div></html>", "url": self.url}
        return [] if script == links.COLLECT else False


class Context:
    def __init__(self, load):
        self.page = Page(load)
        self.close_seconds = getattr(load, "close_seconds", 0)
        self.closed = False

    async def route(self, _pattern, _handler):
        pass

    async def new_page(self):
        return self.page

    async def close(self):
        await asyncio.sleep(self.close_seconds)
        self.closed = True


class Browser:
    def __init__(self, *loads):
        self.loads = list(loads)

    async def new_context(self, **_options):
        self.context = Context(self.loads.pop(0))
        return self.context


class Proxy:
    def __init__(self):
        self.sessions = 0

    def new_session(self, _location):
        self.sessions += 1


class Request:
    async def json(self):
        return {"url": URL}


def status(code, **behaviour):
    def load():
        return GoogleResponse(code)
    load.__dict__.update(behaviour)
    return load


def slow():
    raise server.BrowserTimeout("Timeout exceeded")


def line(lines, prefix):
    """The one log line that starts with prefix; a successful attempt logs after the render."""
    [found] = [text for text in lines if text.startswith(prefix + " ")]
    return found


class RenderTest(unittest.IsolatedAsyncioTestCase):
    async def render(self, *loads):
        self.browser = Browser(*loads)
        renderer = server.Renderer(self.browser, Proxy())
        with self.assertLogs("renderer", "INFO") as logs:
            response = await renderer.render(Request())
            if renderer.closing:
                await renderer.closing
        return response, [record.getMessage() for record in logs.records]

    async def test_logs_each_step_of_a_successful_capture(self):
        response, lines = await self.render(status(200))

        self.assertEqual(response.status, 200)
        self.assertRegex(line(lines, "attempt 1"), r"^attempt 1 outcome=ok context_ms=\d+ load_ms=\d+ google_status=200 "
                                   r"loaded=yes images_ms=\d+ consent_ms=\d+ links_resolved=0 links_ms=\d+ serialize_ms=\d+ kib=0 "
                                   r"close_ms=\d+ total_ms=\d+$")
        self.assertRegex(line(lines, "render"), r"^render outcome=ok queue_ms=\d+ attempts_ms=\d+ attempts=1 located=no "
                                    r"total_ms=\d+$")

    async def test_logs_a_challenge_and_the_retry(self):
        response, lines = await self.render(status(429), status(200))

        self.assertEqual(response.status, 200)
        self.assertRegex(line(lines, "attempt 1"), r"^attempt 1 outcome=challenge .*google_status=429")
        self.assertTrue(any(line.startswith("attempt 2 outcome=ok ") for line in lines))
        self.assertRegex(line(lines, "render"), r"^render outcome=ok .* attempts=2 ")

    async def test_waits_for_the_parsed_page_then_briefly_for_images(self):
        await self.render(status(200))

        (goto, goto_ms), (images, images_ms) = self.browser.context.page.waits
        self.assertEqual((goto, images), ("domcontentloaded", "load"))
        self.assertEqual(goto_ms, server.LOAD_SECONDS * 1000)
        self.assertEqual(images_ms, server.IMAGES_SECONDS * 1000)

    async def test_captures_without_waiting_longer_for_slow_images(self):
        response, lines = await self.render(status(200, images_stall=True))

        self.assertEqual(response.status, 200)
        self.assertRegex(line(lines, "attempt 1"), r"^attempt 1 outcome=ok .*loaded=no ")

    async def test_replaces_a_slow_exit_ip(self):
        response, lines = await self.render(slow, status(200))

        self.assertEqual(response.status, 200)
        self.assertRegex(line(lines, "attempt 1"), r"^attempt 1 outcome=slow context_ms=\d+ load_ms=\d+ close_ms")
        self.assertRegex(line(lines, "render"), r"^render outcome=ok .* attempts=2 ")

    async def test_times_out_when_every_exit_ip_is_slow(self):
        response, lines = await self.render(*[slow] * attempts.MAX_ATTEMPTS)

        self.assertEqual(response.status, 504)
        self.assertRegex(line(lines, "render"), rf"^render outcome=slow .* attempts={attempts.MAX_ATTEMPTS} ")

    async def test_retries_a_challenge_that_appears_after_the_html(self):
        response, lines = await self.render(status(200, late_challenge=True), status(200))

        self.assertEqual(response.status, 200)
        self.assertRegex(line(lines, "attempt 1"), r"^attempt 1 outcome=challenge .*challenge_at=capture ")
        self.assertNotIn("stopped_in", line(lines, "attempt 1"))
        self.assertRegex(line(lines, "attempt 2"), r"^attempt 2 outcome=ok ")

    async def test_names_the_step_a_timeout_interrupted(self):
        response, lines = await self.render(status(200, capture_stalls=True))

        self.assertEqual(response.status, 504)
        self.assertRegex(line(lines, "attempt 1"), r"^attempt 1 outcome=timeout .*stopped_in=serialize ")
        self.assertRegex(line(lines, "render"), r"^render outcome=timeout .* attempts=1 ")

    async def test_a_slow_close_does_not_turn_a_captured_page_into_a_timeout(self):
        with mock.patch.object(server, "DEADLINE", 1.0):
            response, lines = await self.render(status(200, close_seconds=1.2))

        self.assertEqual(response.status, 200)
        self.assertTrue(self.browser.context.closed)
        self.assertRegex(lines[0], r"^render outcome=ok ")
        self.assertRegex(lines[-1], r"^attempt 1 outcome=ok .*close_ms=1[12]\d\d ")


if __name__ == "__main__":
    unittest.main()
