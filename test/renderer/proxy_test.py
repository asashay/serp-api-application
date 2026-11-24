import asyncio
import sys
import unittest
from contextlib import asynccontextmanager
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "renderer"))
from proxy import Proxy


@asynccontextmanager
async def listen(handler):
    async with await asyncio.start_server(handler, "127.0.0.1", 0) as server:
        yield server.sockets[0].getsockname()[1]


class ProxyTest(unittest.IsolatedAsyncioTestCase):
    async def test_only_tunnels_to_lingorep_and_authenticates_upstream(self):
        upstream_requests = []

        async def upstream(reader, writer):
            try:
                upstream_requests.append(await reader.readuntil(b"\r\n\r\n"))
                writer.write(b"HTTP/1.1 200 Connection established\r\n\r\n")
                writer.write(await reader.readexactly(8))
                await writer.drain()
            finally:
                writer.close()
                await writer.wait_closed()

        async with listen(upstream) as upstream_port:
            proxy = Proxy(f"http://127.0.0.1:{upstream_port}", "user", "pass")
            async with listen(proxy.handle) as port:
                for host in ("elsewhere.example:443", "127.0.0.1:3800", "lingorep.com:80"):
                    self.assertIn(b"403 Forbidden", await self.connect(port, host))
                self.assertEqual([], upstream_requests)

                self.assertEqual(b"tunneled", await self.connect(port, "lingorep.com:443", b"tunneled"))

        self.assertEqual([b"CONNECT lingorep.com:443 HTTP/1.1\r\n"
                          b"Host: lingorep.com:443\r\n"
                          b"Proxy-Authorization: Basic dXNlcjpwYXNz\r\n\r\n"], upstream_requests)

    async def test_failed_proxy_auth_closes_the_tunnel(self):
        async def upstream(reader, writer):
            await reader.readuntil(b"\r\n\r\n")
            writer.write(b"HTTP/1.1 407 Proxy Authentication Required\r\n\r\n")
            await writer.drain()
            writer.close()
            await writer.wait_closed()

        async with listen(upstream) as upstream_port:
            async with listen(Proxy(f"http://127.0.0.1:{upstream_port}", "user", "pass").handle) as port:
                self.assertIn(b"502 Bad Gateway", await self.connect(port, "lingorep.com:443"))

    async def connect(self, port, host, payload=None):
        async with asyncio.timeout(3):
            reader, writer = await asyncio.open_connection("127.0.0.1", port)
            try:
                writer.write(f"CONNECT {host} HTTP/1.1\r\n\r\n".encode())
                await writer.drain()
                headers = await reader.readuntil(b"\r\n\r\n")
                if payload:
                    self.assertIn(b"200 Connection Established", headers)
                    writer.write(payload)
                    await writer.drain()
                    return await reader.readexactly(len(payload))
                self.assertEqual(b"", await reader.read())
                return headers
            finally:
                writer.close()
                await writer.wait_closed()


if __name__ == "__main__":
    unittest.main()
