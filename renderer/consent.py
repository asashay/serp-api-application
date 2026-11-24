"""Remove Google's cookie consent dialog from the page before it is captured.

Exit IPs in the EU get a "Before you continue to Google" dialog over the
results. Answering it would mean letting the browser post to
consent.google.com, so instead consent.js takes the dialog, its backdrop and
its scroll lock out of the page. Nothing leaves the Google allowlist, and
every capture starts from a fresh browser context, so nothing has to persist.
"""

import logging
from pathlib import Path

LOG = logging.getLogger("renderer")
REMOVE = (Path(__file__).parent / "consent.js").read_text()


async def remove_consent(page):
    """True when a consent dialog was found and removed.

    A failure leaves the page as it is: the results are still under the dialog.
    """
    try:
        removed = bool(await page.evaluate(REMOVE))
    except Exception as error:  # the page is still worth capturing
        LOG.warning("could not remove the consent dialog: %s", type(error).__name__)
        return False
    if removed:
        LOG.info("removed the consent dialog")
    return removed
