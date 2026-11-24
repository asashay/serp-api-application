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

from attempts import CHALLENGE, render_deadline, with_fresh_ips
from consent import remove_consent
from links import resolve_goto_links
from locations import targeting
from proxy import Proxy, PROXY_PORT

DIRECTORY = Path(__file__).parent
CAPTURE = (DIRECTORY / "capture.js").read_text()
MAX_BYTES = 5 * 1024 * 1024
LOG = logging.getLogger("renderer")


# Production keeps the 30-second deadline. A slow local run (for example
# Firefox under x86 emulation) can raise it with RENDER_TIMEOUT_SECONDS.
DEADLINE = render_deadline(os.environ.get("RENDER_TIMEOUT_SECONDS"))
# Time /goto link resolution may take; it never eats into the capture margin.
RESOLVE_SECONDS = 5 * DEADLINE / 30
# Left after resolving for the DOM capture and the response.
CAPTURE_MARGIN_SECONDS = 3
CLOSE_TIMEOUT = 2 * DEADLINE / 30
# Start another attempt after a challenge only if a page load still fits.
RETRY_MIN_SECONDS = 10 * DEADLINE / 30
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
        try:
            async with asyncio.timeout(DEADLINE):
                async with self.capture_lock:
                    return await with_fresh_ips(
                        lambda remaining: self.capture(url, remaining),
                        lambda: self.proxy.new_session(location), deadline, RETRY_MIN_SECONDS,
                    )
        except (BrowserTimeout, TimeoutError):
            LOG.warning("capture timed out")
            return web.Response(status=504)
        except Error as error:
            # Log only the browser's error code; messages can contain the URL.
            code = re.search(r"\bNS_[A-Z_]+|\bnet::[A-Z_]+", str(error))
            LOG.warning("browser capture failed: %s", code[0] if code else type(error).__name__)
            return web.Response(status=503)

    async def capture(self, url, remaining):
        loop = asyncio.get_running_loop()
        ends_at = loop.time() + remaining
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
            response = await page.goto(url, wait_until="load", timeout=max(1, remaining - 3) * 1000)
            if response is None or not allowed_url(page.url):
                return web.Response(status=503)
            if (response.status in (403, 429) or urlsplit(page.url).path.startswith("/sorry/")
                    or await page.locator(CHALLENGE_SELECTOR).count()):
                return web.Response(status=CHALLENGE)
            if not response.ok:
                return web.Response(status=503)

            await remove_consent(page)

            # The page has loaded, so a slow resolution must not turn it into a
            # timeout: resolve only within what is left, else keep /goto links.
            budget = min(RESOLVE_SECONDS, ends_at - loop.time() - CAPTURE_MARGIN_SECONDS)
            if budget > 0:
                resolved = await resolve_goto_links(context, page, timeout=budget)
                if resolved:
                    LOG.info("resolved %d result links", resolved)
            document = await page.evaluate(CAPTURE)
            html = document["html"].encode()
            if len(html) > MAX_BYTES or not allowed_url(document["url"]):
                return web.Response(status=503)

            return web.Response(body=html, content_type="text/html", charset="utf-8",
                                headers={"X-Page-Url": document["url"]})
        finally:
            await close_or_restart(context)


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
