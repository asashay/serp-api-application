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

from attempts import BROKEN, CHALLENGE, SLOW, render_deadline, with_fresh_ips
from consent import remove_consent
from links import resolve_goto_links
from locations import targeting
from proxy import Proxy, PROXY_PORT
from timings import Timings

DIRECTORY = Path(__file__).parent
CAPTURE = (DIRECTORY / "capture.js").read_text()
MAX_BYTES = 5 * 1024 * 1024
LOG = logging.getLogger("renderer")


# Production keeps the 110-second deadline: room for several fresh exit IPs,
# and still under Cloudflare's 125-second proxy read timeout with the close
# below and Rails' own 4 s on top (PageCapture::Renderer::READ_TIMEOUT). A slow local run (for example Firefox under x86 emulation) can raise
# it with RENDER_TIMEOUT_SECONDS, and every step budget below grows with it.
DEFAULT_DEADLINE = 110
DEADLINE = render_deadline(os.environ.get("RENDER_TIMEOUT_SECONDS"))
SCALE = DEADLINE / DEFAULT_DEADLINE
# Time /goto link resolution may take; it never eats into the capture margin.
RESOLVE_SECONDS = 10 * SCALE
# Left after resolving for the DOM capture and the response.
CAPTURE_MARGIN_SECONDS = 3
CLOSE_TIMEOUT = 4 * SCALE
# An exit IP gets this long to deliver Google's HTML; a slower one is replaced
# by a new IP while there is still time for another attempt.
LOAD_SECONDS = 24 * SCALE
# After the HTML, how long to wait for the full load, which fills in the
# result images. A slow subresource then costs at most this, not the deadline.
IMAGES_SECONDS = 8 * SCALE
# Start another attempt after a challenge or slow IP only if a page load still fits.
RETRY_MIN_SECONDS = 20 * SCALE
# The response header that carries the render's timing summary (no content).
RENDER_LOG = "X-Render-Log"
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
        summaries = []

        async def attempt(remaining):
            nonlocal attempts
            attempts += 1
            return await self.capture(url, remaining, attempts, summaries)

        outcome = "error"
        response = None
        try:
            async with asyncio.timeout(DEADLINE):
                async with self.capture_lock:
                    timings.begin("attempts")
                    response = await with_fresh_ips(
                        attempt, lambda: self.proxy.new_session(location), deadline, RETRY_MIN_SECONDS,
                    )
                    timings.finish()
                    outcome = {200: "ok", CHALLENGE: "challenge", SLOW: "slow", BROKEN: "browser_error"}.get(
                        response.status, f"status_{response.status}")
                    if response.status == SLOW:
                        response = web.Response(status=504)
                    elif response.status == BROKEN:
                        response = web.Response(status=503)
        except (BrowserTimeout, TimeoutError):
            outcome = "timeout"
            response = web.Response(status=504)
        except Error as error:
            outcome = "browser_error"
            timings.note(error=error_code(error))
            response = web.Response(status=503)
        finally:
            timings.note(attempts=attempts, located="yes" if location else "no")
            line = timings.line(outcome)
            LOG.info("render %s", line)

        # The container's output is not kept by Cloudflare, so the same
        # summary goes back to Rails and on to the Worker, whose logs are.
        response.headers[RENDER_LOG] = " | ".join([f"render {line}", *summaries])
        return response

    async def capture(self, url, remaining, number=1, summaries=None):
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
            timings.note(kib=len(html) // 1024, **probe_fields(document.get("probe")))
            return web.Response(body=html, content_type="text/html", charset="utf-8",
                                headers={"X-Page-Url": document["url"]})
        except asyncio.CancelledError:
            outcome = "cancelled"
            raise
        except (BrowserTimeout, TimeoutError):
            outcome = "timeout"
            raise
        except Error as error:
            outcome = "browser_error"
            timings.note(error=error_code(error))
            # A proxy error, reset connection or interrupted navigation fails
            # this exit IP only, so the next attempt gets a new one. Anything
            # else would fail the same way again, so it is not retried.
            if not network_error(error):
                raise
            return web.Response(status=BROKEN)
        finally:
            # Name the step an error or the deadline interrupted.
            if timings.step:
                timings.note(stopped_in=timings.step)
            if summaries is not None:
                summaries.append(f"attempt {number} {timings.snapshot(outcome)}")
            timings.begin("close")
            closing = asyncio.ensure_future(close_and_log(context, timings, number, outcome))
            if outcome == "ok":
                # The page is captured: answer now and let the next capture
                # wait for this close instead.
                self.closing = closing
            else:
                await closing


# Firefox and Chromium network error codes, such as NS_ERROR_NET_RESET.
NETWORK_CODE = re.compile(r"\bNS_[A-Z_]+|\bnet::[A-Z_]+")


def error_code(error):
    """The browser's error code only; error messages can contain the URL."""
    code = NETWORK_CODE.search(str(error))
    return code[0] if code else type(error).__name__


# Navigation that Google's redirects or scripts interrupt, worded by Playwright.
INTERRUPTED = re.compile(r"execution context was destroyed|navigation|interrupted by another", re.IGNORECASE)


def network_error(error):
    """Whether a browser error came from the exit IP's network or navigation."""
    return bool(NETWORK_CODE.search(str(error)) or INTERRUPTED.search(str(error)))


def probe_fields(probe):
    """capture.js's structural facts about the page, made safe for one log line."""
    if not isinstance(probe, dict):
        return {}
    return {name: re.sub(r"[^\w./-]", "", str(value))[:40] for name, value in probe.items()
            if re.fullmatch(r"[a-z_]{1,20}", str(name))}


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
