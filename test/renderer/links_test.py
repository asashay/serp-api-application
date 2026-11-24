import asyncio
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "renderer"))
from links import COLLECT, REQUEST, REWRITE, redirect_target, resolve_goto_links

GOTO = "https://www.google.com/goto?url="


class Response:
    def __init__(self, url, status, location=None):
        self.url = url
        self.status = status
        self.headers = {"location": location} if location else {}


class Context:
    def __init__(self):
        self.listeners = []

    def on(self, event, listener):
        assert event == "response"
        self.listeners.append(listener)

    def remove_listener(self, event, listener):
        assert event == "response"
        self.listeners.remove(listener)

    def emit(self, response):
        for listener in list(self.listeners):
            listener(response)


class Page:
    """Answers the three scripts the way Firefox would for a /goto results page."""

    def __init__(self, context, links, responses):
        self.context = context
        self.links = links
        self.responses = responses
        self.calls = []
        self.requested = []
        self.rewritten = None

    async def evaluate(self, script, argument):
        self.calls.append(script)
        if script == COLLECT:
            return self.links[:argument]
        if script == REQUEST:
            url, timeout = argument
            self.requested.append(url)
            assert timeout > 0
            responses = [response for response in self.responses if response.url == url]
            # The last link's event lands after the page's promise settles, as Playwright allows.
            for response in responses:
                if url == self.links[-1]:
                    asyncio.get_running_loop().call_soon(self.context.emit, response)
                else:
                    self.context.emit(response)
            return None
        if script == REWRITE:
            self.rewritten = argument
            return None
        raise AssertionError("unexpected script")


class RedirectTargetTest(unittest.TestCase):
    def test_accepts_only_absolute_http_redirects(self):
        self.assertEqual("https://example.com/a?b=1", redirect_target(302, "https://example.com/a?b=1"))
        self.assertEqual("http://example.com/", redirect_target(307, "http://example.com/"))
        for status, location in [
            (200, "https://example.com/"),
            (302, None),
            (302, "/search?q=a"),
            (302, "javascript:alert(1)"),
            (302, "https://user:pass@example.com/"),
            (302, "https:///path"),
            (302, "https://example.com/" + "a" * 2048),
            (302, "http://[::1"),
        ]:
            self.assertIsNone(redirect_target(status, location), location)


class ResolveGotoLinksTest(unittest.IsolatedAsyncioTestCase):
    async def test_rewrites_redirected_links_and_keeps_the_rest(self):
        context = Context()
        links = [GOTO + "a", GOTO + "b", GOTO + "c"]
        page = Page(context, links, [
            Response(GOTO + "a", 302, "https://coffeegeek.com/grinders"),
            Response(GOTO + "b", 200),
            Response(GOTO + "c", 302, "https://example.org/late"),
        ])

        context.emit(Response("https://www.gstatic.com/unrelated.js", 200))
        self.assertEqual(2, await resolve_goto_links(context, page, timeout=5))
        self.assertEqual(links, page.requested)
        self.assertEqual({GOTO + "a": "https://coffeegeek.com/grinders", GOTO + "c": "https://example.org/late"},
                         page.rewritten)
        self.assertEqual([], context.listeners)

    async def test_stops_requesting_when_the_budget_runs_out(self):
        context = Context()
        links = [GOTO + "a", GOTO + "b", GOTO + "c"]
        page = Page(context, links, [Response(GOTO + "a", 302, "https://example.com/a")])

        self.assertEqual(1, await resolve_goto_links(context, page, timeout=0.1))
        self.assertEqual([GOTO + "a"], page.requested)
        self.assertEqual({GOTO + "a": "https://example.com/a"}, page.rewritten)

    async def test_late_event_wait_stays_within_the_budget(self):
        context = Context()
        page = Page(context, [GOTO + "a"], [])
        loop = asyncio.get_running_loop()

        started = loop.time()
        self.assertEqual(0, await resolve_goto_links(context, page, timeout=0.05))
        self.assertLess(loop.time() - started, 0.5)
        self.assertEqual([], context.listeners)

    async def test_does_nothing_without_goto_links(self):
        context = Context()
        page = Page(context, [], [])

        self.assertEqual(0, await resolve_goto_links(context, page, timeout=5))
        self.assertEqual([COLLECT], page.calls)
        self.assertEqual([], context.listeners)


if __name__ == "__main__":
    unittest.main()
