"""Restrict the browser's HTTPS tunnels to the authorized origins."""

import asyncio
import base64
import logging
import secrets
from contextlib import suppress
from urllib.parse import urlsplit

DESTINATIONS = {b"www.google.com:443", b"www.gstatic.com:443", b"ssl.gstatic.com:443"}
PROXY_PORT = 3801
LOG = logging.getLogger("renderer.proxy")


class Proxy:
    def __init__(self, server, username, password):
        endpoint = urlsplit(server)
        if (
            endpoint.scheme not in ("http", "https") or not endpoint.hostname
            or endpoint.username or endpoint.password or endpoint.path not in ("", "/")
            or endpoint.query or endpoint.fragment or not username or not password
        ):
            raise ValueError("Invalid DataImpulse proxy configuration")
        self.host = endpoint.hostname
        self.port = endpoint.port or (443 if endpoint.scheme == "https" else 80)
        self.tls = endpoint.scheme == "https"
        self.username = username
        self.password = password
        self.session = None
        self.targeting = None

    def new_session(self, targeting=None):
        """Pin the following tunnels to one new exit IP, optionally in a place.

        DataImpulse keeps the same IP for tunnels whose username carries the
        same sessid parameter, and a new sessid gets a new IP. `targeting` is a
        location's parameters from renderer/locations.py, such as
        "cr.us;city.austin". Captures run one at a time, so each attempt sets
        its own session before Firefox connects.
        """
        self.session = secrets.token_hex(8)
        self.targeting = targeting

    @property
    def authorization(self):
        username = self.username
        parameters = [part for part in (self.targeting, self.session and f"sessid.{self.session}") if part]
        if parameters:
            separator = ";" if "__" in username else "__"
            username = f"{username}{separator}{';'.join(parameters)}"
        credentials = base64.b64encode(f"{username}:{self.password}".encode())
        return b"Proxy-Authorization: Basic " + credentials + b"\r\n\r\n"

    async def handle(self, browser_reader, browser_writer):
        upstream_writer = None
        try:
            async with asyncio.timeout(10):
                request = await browser_reader.readuntil(b"\r\n\r\n")
                method, target, _version = request.split(b"\r\n", 1)[0].split()
                target = target.lower()
                if method != b"CONNECT" or target not in DESTINATIONS:
                    browser_writer.write(b"HTTP/1.1 403 Forbidden\r\nConnection: close\r\n\r\n")
                    await browser_writer.drain()
                    return

                upstream_reader, upstream_writer = await asyncio.open_connection(
                    self.host, self.port, ssl=self.tls,
                )
                upstream_writer.write(
                    b"CONNECT " + target + b" HTTP/1.1\r\nHost: " + target + b"\r\n" + self.authorization,
                )
                await upstream_writer.drain()
                response = await upstream_reader.readuntil(b"\r\n\r\n")
                status = response.split(b"\r\n", 1)[0].split()[1:2]
                if status != [b"200"]:
                    LOG.warning("proxy refused tunnel: %s", (status or [b"none"])[0].decode(errors="replace")[:3])
                    browser_writer.write(b"HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\n\r\n")
                    await browser_writer.drain()
                    return
                browser_writer.write(b"HTTP/1.1 200 Connection Established\r\n\r\n")
                await browser_writer.drain()

            async with asyncio.TaskGroup() as tasks:
                outbound = tasks.create_task(relay(browser_reader, upstream_writer))
                inbound = tasks.create_task(relay(upstream_reader, browser_writer))
                _, pending = await asyncio.wait((outbound, inbound), return_when=asyncio.FIRST_COMPLETED)
                for task in pending:
                    task.cancel()
        except (OSError, asyncio.IncompleteReadError, asyncio.LimitOverrunError, ValueError) as error:
            LOG.warning("proxy tunnel failed: %s", type(error).__name__)
        finally:
            browser_writer.close()
            if upstream_writer:
                upstream_writer.close()
            with suppress(OSError, TimeoutError):
                async with asyncio.timeout(2):
                    await browser_writer.wait_closed()
                    if upstream_writer:
                        await upstream_writer.wait_closed()


async def relay(reader, writer):
    with suppress(OSError):
        while chunk := await reader.read(64 * 1024):
            writer.write(chunk)
            await writer.drain()
