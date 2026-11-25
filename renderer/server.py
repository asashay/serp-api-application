import asyncio
from contextlib import AsyncExitStack
import logging
import os
import re
from pathlib import Path
import signal
from urllib.parse import urlsplit

from aiohttp import web
from invisible_playwright.async_api import InvisiblePlaywright
from invisible_playwright._pw.async_api import Error, TimeoutError as BrowserTimeout

from attempts import CHALLENGE, SLOW, render_deadline, with_fresh_ips
from consent import remove_consent
from links import resolve_goto_links
from locations import targeting
from proxy import Proxy, PROXY_PORT
from timings import Timings

DIRECTORY = Path(__file__).parent
CAPTURE = (DIRECTORY / "capture.js").read_text()
MAX_BYTES = 5 * 1024 * 1024
LOG = logging.getLogger("renderer")


# Production keeps the 60-second deadline, which leaves room for several
# fresh exit IPs. A slow local run (for example Firefox under x86 emulation)
# can raise it with RENDER_TIMEOUT_SECONDS; every step budget below scales with
# it, so at the default they are the seconds written in each fraction.
DEADLINE = render_deadline(os.environ.get("RENDER_TIMEOUT_SECONDS"))
# Time /goto link resolution may take; it never eats into the capture margin.
RESOLVE_SECONDS = 5 * DEADLINE / 60
# Left after resolving for the DOM capture and the response.
CAPTURE_MARGIN_SECONDS = 3
CLOSE_TIMEOUT = 2 * DEADLINE / 60
# An exit IP gets this long to deliver Google's HTML; a slower one is replaced
# by a new IP while there is still time for another attempt.
LOAD_SECONDS = 12 * DEADLINE / 60
# After the HTML, how long to wait for the full load, which fills in the
# result images. A slow subresource then costs at most this, not the deadline.
IMAGES_SECONDS = 4 * DEADLINE / 60
# Start another attempt after a challenge or slow IP only if a page load still fits.
RETRY_MIN_SECONDS = 10 * DEADLINE / 60
CHALLENGE_SELECTOR = 'form#captcha-form, form[action*="/sorry/"], iframe[src*="/recaptcha/"]'


ALLOWED_HOSTS = {"www.google.com", "www.gstatic.com", "ssl.gstatic.com"}


def allowed_url(url):
    if not isinstance(url, str):
        return False

    try:
        parts = urlsplit(url)
        return parts.scheme == "https" and parts.netloc in ALLOWED_HOSTS
    except ValueError:
        return False


class Renderer:
    def __init__(self, browser, proxy):
        self.browser = browser
        self.proxy = proxy
        self.capture_lock = asyncio.Lock()
        # The close of the last successful capture, which runs after its
        # response so it cannot push a finished page past the deadline.
        self.closing = None

    async def health(self, _request):
        return web.Response(status=200 if self.browser.is_connected() else 503)

    async def render(self, request):
        try:
            payload = await request.json()
        except (ValueError, TypeError):
            return web.Response(status=400)

        url = payload.get("url") if isinstance(payload, dict) else None
        known, location = targeting(payload.get("location")) if isinstance(payload, dict) else (False, None)
        if not allowed_url(url) or not known:
            return web.Response(status=400)
        if self.proxy is None:
            return web.Response(status=503)

        # An admitted capture has already used quota, so wait for a running
        # render to finish instead of failing. The deadline covers the wait.
        deadline = asyncio.get_running_loop().time() + DEADLINE
        timings = Timings()
        timings.begin("queue")
        attempts = 0

        async def attempt(remaining):
            nonlocal attempts
            attempts += 1
            return await self.capture(url, remaining, attempts)

        outcome = "error"
        try:
            async with asyncio.timeout(DEADLINE):
                async with self.capture_lock:
                    timings.begin("attempts")
                    response = await with_fresh_ips(
                        attempt, lambda: self.proxy.new_session(location), deadline, RETRY_MIN_SECONDS,
                    )
                    timings.finish()
                    outcome = {200: "ok", CHALLENGE: "challenge", SLOW: "slow"}.get(
                        response.status, f"status_{response.status}")
                    return web.Response(status=504) if response.status == SLOW else response
        except (BrowserTimeout, TimeoutError):
            outcome = "timeout"
            return web.Response(status=504)
        except Error as error:
            # Log only the browser's error code; messages can contain the URL.
            code = re.search(r"\bNS_[A-Z_]+|\bnet::[A-Z_]+", str(error))
            outcome = "browser_error"
            timings.note(error=code[0] if code else type(error).__name__)
            return web.Response(status=503)
        finally:
            timings.note(attempts=attempts, located="yes" if location else "no")
            LOG.info("render %s", timings.line(outcome))

    async def capture(self, url, remaining, number=1):
        loop = asyncio.get_running_loop()
        ends_at = loop.time() + remaining
        timings = Timings()
        timings.begin("context")
        outcome = "error"
        if self.closing:
            await asyncio.wait({self.closing})
        context = await self.browser.new_context(
            proxy={"server": f"http://127.0.0.1:{PROXY_PORT}"},
            viewport={"width": 1366, "height": 900},
            service_workers="block",
            accept_downloads=False,
        )

        async def restrict(route):
            if allowed_url(route.request.url):
                await route.continue_()
            else:
                await route.abort()

        try:
            await context.route("**/*", restrict)
            page = await context.new_page()
            # Google sends the results in the HTML, so the page is usable once
            # it is parsed; images get a short wait of their own below.
            timings.begin("load")
            try:
                response = await page.goto(url, wait_until="domcontentloaded",
                                           timeout=max(1, min(LOAD_SECONDS, remaining - 3)) * 1000)
            except BrowserTimeout:
                timings.finish()
                outcome = "slow"
                return web.Response(status=SLOW)
            timings.finish()
            if response is None or not allowed_url(page.url):
                outcome = "off_site"
                return web.Response(status=503)
            timings.note(google_status=response.status)
            if response.status in (403, 429) or await challenged(page):
                outcome = "challenge"
                timings.note(challenge_at="load")
                return web.Response(status=CHALLENGE)
            if not response.ok:
                outcome = "google_error"
                return web.Response(status=503)

            # Google's scripts set most result images (inline data: URIs)
            # while the page loads. Wait for that briefly, then capture anyway.
            timings.begin("images")
            wait = min(IMAGES_SECONDS, ends_at - loop.time() - CAPTURE_MARGIN_SECONDS)
            loaded = False
            if wait > 0:
                try:
                    await page.wait_for_load_state("load", timeout=wait * 1000)
                    loaded = True
                except Error:
                    pass
            timings.note(loaded="yes" if loaded else "no")

            timings.begin("consent")
            await remove_consent(page)

            # The page is ready, so a slow resolution must not turn it into a
            # timeout: resolve only within what is left, else keep /goto links.
            budget = min(RESOLVE_SECONDS, ends_at - loop.time() - CAPTURE_MARGIN_SECONDS)
            timings.begin("links")
            if budget > 0:
                timings.note(links_resolved=await resolve_goto_links(context, page, timeout=budget))
            # Google's scripts can still swap in a challenge or redirect to
            # /sorry/ while the page finishes loading. Check again, so it is
            # retried here instead of reaching the parser.
            timings.finish()
            if await challenged(page):
                outcome = "challenge"
                timings.note(challenge_at="capture")
                return web.Response(status=CHALLENGE)

            timings.begin("serialize")
            document = await page.evaluate(CAPTURE)
            html = document["html"].encode()
            timings.finish()
            if len(html) > MAX_BYTES or not allowed_url(document["url"]):
                outcome = "too_large_or_off_site"
                return web.Response(status=503)

            outcome = "ok"
            timings.note(kib=len(html) // 1024)
            return web.Response(body=html, content_type="text/html", charset="utf-8",
                                headers={"X-Page-Url": document["url"]})
        except asyncio.CancelledError:
            outcome = "cancelled"
            raise
        except (BrowserTimeout, TimeoutError):
            outcome = "timeout"
            raise
        finally:
            # Name the step an error or the deadline interrupted.
            if timings.step:
                timings.note(stopped_in=timings.step)
            timings.begin("close")
            closing = asyncio.ensure_future(close_and_log(context, timings, number, outcome))
            if outcome == "ok":
                # The page is captured: answer now and let the next capture
                # wait for this close instead.
                self.closing = closing
            else:
                await closing


async def challenged(page):
    """Whether the page is a challenge, by its /sorry/ address or a CAPTCHA.

    Rails' parser checks the captured page with the same selector.
    """
    return urlsplit(page.url).path.startswith("/sorry/") or bool(await page.locator(CHALLENGE_SELECTOR).count())


async def close_and_log(context, timings, number, outcome):
    try:
        await close_or_restart(context)
        timings.finish()
    finally:
        LOG.info("attempt %d %s", number, timings.line(outcome))


async def close_or_restart(context):
    """Close the context, or stop the process so supervisord restarts Firefox.

    The close keeps running if the capture deadline cancels this task, so a
    timed-out capture still gets its context closed or the browser replaced.
    """
    closing = asyncio.ensure_future(context.close())
    try:
        await asyncio.wait({closing}, timeout=CLOSE_TIMEOUT)
    except asyncio.CancelledError:
        await asyncio.wait({closing}, timeout=CLOSE_TIMEOUT)
        raise
    finally:
        if not closing.done() or closing.cancelled() or closing.exception() is not None:
            LOG.error("browser context did not close; restarting renderer")
            os.kill(os.getpid(), signal.SIGTERM)


async def main():
    stop = asyncio.Event()
    asyncio.get_running_loop().add_signal_handler(signal.SIGTERM, stop.set)
    credentials = [os.environ.pop(name, "") for name in (
        "DATAIMPULSE_SERVER", "DATAIMPULSE_USERNAME", "DATAIMPULSE_PASSWORD",
    )]
    proxy = Proxy(*credentials) if all(credentials) else None
    if proxy is None:
        LOG.warning("DataImpulse credentials are missing")

    async with AsyncExitStack() as stack:
        if proxy:
            tunnel = await asyncio.start_server(proxy.handle, "127.0.0.1", PROXY_PORT, limit=16 * 1024)
            await stack.enter_async_context(tunnel)

        browser = await stack.enter_async_context(InvisiblePlaywright(
            headless=True, humanize=False, locale="en-US", extra_prefs={
                "network.proxy.allow_hijacking_localhost": True,
                "media.peerconnection.enabled": False,
            },
        ))
        browser.on("disconnected", lambda _: stop.set())
        service = Renderer(browser, proxy)
        app = web.Application(client_max_size=4096)
        app.router.add_get("/health", service.health)
        app.router.add_post("/render", service.render)
        runner = web.AppRunner(app, access_log=None)
        await runner.setup()
        stack.push_async_callback(runner.cleanup)
        await web.TCPSite(runner, "127.0.0.1", 3800).start()
        await stop.wait()


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO)
    asyncio.run(main())
