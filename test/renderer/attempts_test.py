import asyncio
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "renderer"))
from attempts import CHALLENGE, SLOW, render_deadline, with_fresh_ips


class Response:
    def __init__(self, status):
        self.status = status


class Attempts:
    def __init__(self, statuses, seconds=0):
        self.statuses = list(statuses)
        self.seconds = seconds
        self.sessions = 0
        self.remaining = []

    def new_session(self):
        self.sessions += 1

    async def __call__(self, remaining):
        self.remaining.append(remaining)
        await asyncio.sleep(self.seconds)
        return Response(self.statuses.pop(0))


class RenderDeadlineTest(unittest.TestCase):
    def test_raises_only_with_finite_values_above_110(self):
        self.assertEqual(240.0, render_deadline("240"))
        self.assertEqual(150.5, render_deadline("150.5"))
        with self.assertLogs("renderer", "WARNING"):
            self.assertEqual(110.0, render_deadline("150s"))
        for value in (None, "", "10", "60", "110", "-5", "inf", "nan"):
            self.assertEqual(110.0, render_deadline(value), value)


class WithFreshIpsTest(unittest.IsolatedAsyncioTestCase):
    def deadline(self, seconds):
        return asyncio.get_running_loop().time() + seconds

    async def test_retries_challenges_with_a_new_session_each_time(self):
        attempts = Attempts([CHALLENGE, CHALLENGE, 200])

        response = await with_fresh_ips(attempts, attempts.new_session, self.deadline(30), min_seconds=1)

        self.assertEqual(200, response.status)
        self.assertEqual(3, attempts.sessions)
        self.assertTrue(all(0 < remaining <= 30 for remaining in attempts.remaining))

    async def test_does_not_retry_other_failures(self):
        attempts = Attempts([503, 200])

        response = await with_fresh_ips(attempts, attempts.new_session, self.deadline(30), min_seconds=1)

        self.assertEqual(503, response.status)
        self.assertEqual(1, attempts.sessions)

    async def test_retries_a_slow_exit_ip_like_a_challenge(self):
        attempts = Attempts([SLOW, CHALLENGE, 200])

        response = await with_fresh_ips(attempts, attempts.new_session, self.deadline(30), min_seconds=1)

        self.assertEqual(200, response.status)
        self.assertEqual(3, attempts.sessions)

    async def test_returns_the_challenge_after_the_last_attempt(self):
        attempts = Attempts([CHALLENGE] * 5)

        response = await with_fresh_ips(attempts, attempts.new_session, self.deadline(30), min_seconds=1, max_attempts=3)

        self.assertEqual(CHALLENGE, response.status)
        self.assertEqual(3, attempts.sessions)

    async def test_stops_when_another_page_load_would_not_fit(self):
        attempts = Attempts([CHALLENGE, 200], seconds=0.05)

        response = await with_fresh_ips(attempts, attempts.new_session, self.deadline(1), min_seconds=0.99)

        self.assertEqual(CHALLENGE, response.status)
        self.assertEqual(1, attempts.sessions)


if __name__ == "__main__":
    unittest.main()
