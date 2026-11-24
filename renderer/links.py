"""Replace Google's opaque /goto result links with their destinations.

Google can link organic results through /goto?url=<encrypted token>, and the
destination appears only in that endpoint's 302 Location header. The page
requests each link itself with redirect: "manual", so the request carries the
browser's own fingerprint and cookies and the redirect is never followed. The
browser's network events still expose the Location header, which replaces the
link in the DOM before it is captured. The Google link stays in data-goto.

Requests go one at a time with a short gap: a burst of /goto requests gets a
200 holding page (a delayed meta refresh) instead of the redirect.
"""

import asyncio
from urllib.parse import urlsplit

LIMIT = 12
GAP_SECONDS = 0.3
MAX_URL_LENGTH = 2048

COLLECT = """(limit) => {
  const links = [...document.querySelectorAll('#rso a[href^="/goto?"]')]
    .filter((anchor) => anchor.querySelector("h3"))
    .map((anchor) => anchor.href)
  return [...new Set(links)].slice(0, limit)
}"""

REQUEST = """async ([url, timeout]) => {
  try {
    await fetch(url, { redirect: "manual", credentials: "include", signal: AbortSignal.timeout(timeout) })
  } catch {}
}"""

REWRITE = """(targets) => {
  for (const anchor of document.querySelectorAll('#rso a[href^="/goto?"]')) {
    const target = targets[anchor.href]
    if (!target) continue
    // Keep Google's link for the parser's redirect_link.
    anchor.setAttribute("data-goto", anchor.href)
    anchor.setAttribute("href", target)
  }
}"""


def redirect_target(status, location):
    """Return the destination of a /goto redirect, or None if it is not one."""
    if status not in (301, 302, 303, 307, 308) or not isinstance(location, str):
        return None
    if len(location) > MAX_URL_LENGTH:
        return None

    try:
        parts = urlsplit(location)
        hostname = parts.hostname
    except ValueError:
        return None
    if parts.scheme not in ("http", "https") or not hostname or parts.username or parts.password:
        return None
    return location


async def resolve_goto_links(context, page, timeout):
    """Rewrite the page's /goto result links in place within `timeout` seconds in total.

    Links that are not resolved in time, or that answer without a redirect,
    stay as they are and the parser skips them.
    """
    urls = await page.evaluate(COLLECT, LIMIT)
    if not urls:
        return 0

    loop = asyncio.get_running_loop()
    deadline = loop.time() + timeout
    pending = {url: loop.create_future() for url in urls}

    def on_response(response):
        future = pending.get(response.url)
        if future and not future.done():
            future.set_result(redirect_target(response.status, response.headers.get("location")))

    context.on("response", on_response)
    try:
        for index, url in enumerate(urls):
            if index:
                await asyncio.sleep(GAP_SECONDS)
            remaining = deadline - loop.time()
            if remaining <= 0:
                break
            await page.evaluate(REQUEST, [url, max(1, int(remaining * 1000))])
        # Response events can arrive just after the page's promise settles;
        # wait for them only within the budget.
        late = min(1, deadline - loop.time())
        if late > 0:
            await asyncio.wait(pending.values(), timeout=late)
    finally:
        context.remove_listener("response", on_response)

    targets = {url: future.result() for url, future in pending.items() if future.done() and future.result()}
    if targets:
        await page.evaluate(REWRITE, targets)
    return len(targets)
