"""Restrict the browser's HTTPS tunnels to the authorized origin."""

import asyncio
import base64
import logging
from contextlib import suppress
from urllib.parse import urlsplit

DESTINATION = b"lingorep.com:443"
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
        credentials = base64.b64encode(f"{username}:{password}".encode())
        self.request = (
            b"CONNECT " + DESTINATION + b" HTTP/1.1\r\n"
            b"Host: " + DESTINATION + b"\r\n"
            b"Proxy-Authorization: Basic " + credentials + b"\r\n\r\n"
        )

    async def handle(self, browser_reader, browser_writer):
        upstream_writer = None
        try:
            async with asyncio.timeout(10):
                request = await browser_reader.readuntil(b"\r\n\r\n")
                method, target, _version = request.split(b"\r\n", 1)[0].split()
                if method != b"CONNECT" or target.lower() != DESTINATION:
                    browser_writer.write(b"HTTP/1.1 403 Forbidden\r\nConnection: close\r\n\r\n")
                    await browser_writer.drain()
                    return

                upstream_reader, upstream_writer = await asyncio.open_connection(
                    self.host, self.port, ssl=self.tls,
                )
                upstream_writer.write(self.request)
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
