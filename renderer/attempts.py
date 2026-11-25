"""Retry a capture from a new exit IP when the current one fails it.

DataImpulse residential IPs vary in reputation and speed. Google answers some
of them with a challenge (HTTP 429 or 403, a /sorry/ page or a CAPTCHA form)
instead of results, and some are too slow to load the page in time. A new
proxy session gets a new IP, so such a capture is retried with a fresh browser
context while the deadline leaves enough time for another page load.
"""

import asyncio
import logging
import math

CHALLENGE = 429
# The exit IP did not deliver Google's page within the per-attempt load limit.
SLOW = 408
RETRY = {CHALLENGE: "google challenge", SLOW: "slow exit IP"}
MAX_ATTEMPTS = 3
LOG = logging.getLogger("renderer")


def render_deadline(value):
    """Seconds allowed per capture from RENDER_TIMEOUT_SECONDS.

    Finite values above 30 raise the deadline; anything else keeps 30, so a
    typo never stops the renderer. Rails applies the same rules
    (PageCapture::Renderer.deadline) to its read timeout.
    """
    try:
        seconds = float(value or 30)
    except (TypeError, ValueError):
        LOG.warning("ignoring invalid RENDER_TIMEOUT_SECONDS")
        return 30.0
    return seconds if math.isfinite(seconds) and seconds > 30 else 30.0


async def with_fresh_ips(attempt, new_session, deadline, min_seconds, max_attempts=MAX_ATTEMPTS):
    """Run attempt(remaining_seconds) until it returns a response worth keeping.

    `deadline` is an event-loop time. Each attempt starts a new proxy session
    first. A challenge or slow response is retried; the last one is returned
    when attempts or time run out.
    """
    loop = asyncio.get_running_loop()
    for number in range(1, max_attempts + 1):
        new_session()
        response = await attempt(deadline - loop.time())
        reason = RETRY.get(response.status)
        if reason is None:
            return response
        if number == max_attempts or deadline - loop.time() < min_seconds:
            LOG.warning("%s on attempt %d; giving up", reason, number)
            return response
        LOG.warning("%s on attempt %d; retrying from a new exit IP", reason, number)
    return response
