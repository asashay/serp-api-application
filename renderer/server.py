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

from proxy import Proxy, PROXY_PORT

DIRECTORY = Path(__file__).parent
CAPTURE = (DIRECTORY / "capture.js").read_text()
MAX_BYTES = 5 * 1024 * 1024
LOG = logging.getLogger("renderer")


def allowed_url(url):
    if not isinstance(url, str):
        return False

    try:
        parts = urlsplit(url)
        return parts.scheme == "https" and parts.netloc == "lingorep.com"
    except ValueError:
        return False


class Renderer:
    def __init__(self, browser, proxy_configured):
        self.browser = browser
        self.proxy_configured = proxy_configured
        self.capture_lock = asyncio.Lock()

    async def health(self, _request):
        return web.Response(status=200 if self.browser.is_connected() else 503)

    async def render(self, request):
        try:
            payload = await request.json()
        except (ValueError, TypeError):
            return web.Response(status=400)

        url = payload.get("url") if isinstance(payload, dict) else None
        if not allowed_url(url):
            return web.Response(status=400)
        if not self.proxy_configured:
            return web.Response(status=503)

        # An admitted capture has already used quota, so wait for a running
        # render to finish instead of failing. The deadline covers the wait.
        try:
            async with asyncio.timeout(30):
                async with self.capture_lock:
                    return await self.capture(url)
        except (BrowserTimeout, TimeoutError):
            LOG.warning("capture timed out")
            return web.Response(status=504)
        except Error as error:
            # Log only the browser's error code; messages can contain the URL.
            code = re.search(r"\bNS_[A-Z_]+|\bnet::[A-Z_]+", str(error))
            LOG.warning("browser capture failed: %s", code[0] if code else type(error).__name__)
            return web.Response(status=503)

    async def capture(self, url):
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
            response = await page.goto(url, wait_until="load", timeout=27_000)
            if response is None or not allowed_url(page.url):
                return web.Response(status=503)
            if response.status == 404:
                return web.Response(status=404)
            if not response.ok:
                return web.Response(status=503)

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
        await asyncio.wait({closing}, timeout=2)
    except asyncio.CancelledError:
        await asyncio.wait({closing}, timeout=2)
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
        service = Renderer(browser, proxy is not None)
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
