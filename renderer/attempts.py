"""Retry a capture from a new exit IP when Google challenges the current one.

DataImpulse residential IPs vary in reputation, and Google answers some of
them with a challenge (HTTP 429 or 403, a /sorry/ page or a CAPTCHA form)
instead of results. A new proxy session gets a new IP, so a challenged
capture is retried with a fresh browser context while the deadline leaves
enough time for another page load.
"""

import asyncio
import logging
import math

CHALLENGE = 429
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
    """Run attempt(remaining_seconds) until it returns a non-challenge response.

    `deadline` is an event-loop time. Each attempt starts a new proxy session
    first. The last challenge response is returned when attempts or time run out.
    """
    loop = asyncio.get_running_loop()
    for number in range(1, max_attempts + 1):
        new_session()
        response = await attempt(deadline - loop.time())
        if response.status != CHALLENGE:
            return response
        if number == max_attempts or deadline - loop.time() < min_seconds:
            LOG.warning("google challenge on attempt %d; giving up", number)
            return response
        LOG.warning("google challenge on attempt %d; retrying from a new exit IP", number)
    return response
