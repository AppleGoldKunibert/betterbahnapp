"""Tests for proxy.py: `python3 -m unittest Server/bahnde-proxy/proxy_test.py` (needs aiohttp; no network)."""

import asyncio
import sys
import unittest
from pathlib import Path

from aiohttp.test_utils import TestClient, TestServer

sys.path.insert(0, str(Path(__file__).parent))
import proxy  # noqa: E402

SECRET = "test-secret"
# Signed by Cloudflare/shared/appattest.mjs: signToken({t: "a", kid: "key-1", exp: 4102444800}, "test-secret").
WORKER_TOKEN = "eyJ0IjoiYSIsImtpZCI6ImtleS0xIiwiZXhwIjo0MTAyNDQ0ODAwfQ.J3Otk9jGZq0noI7DXY3hTRnm6YDpdOHuOGRO_H8j_So"  # gitleaks:allow (signed with the dummy key above)
ORTE = "/web/api/reiseloesung/orte?suchbegriff=Berlin&typ=ALL&limit=1"


class FakeBahnDe:
    """bahn.de stand-in: answers `status` with a body naming the URL, counts and records requests."""

    def __init__(self, status=200, delay=0):
        self.status = status
        self.delay = delay
        self.urls = []
        self.resets = 0
        self.running = 0
        self.most_running = 0

    def reset(self):
        self.resets += 1

    async def __call__(self, url):
        self.urls.append(url)
        self.running += 1
        self.most_running = max(self.most_running, self.running)
        try:
            if self.delay:
                await asyncio.sleep(self.delay)
            return proxy.Answer(self.status, f'{{"url": "{url}"}}'.encode())
        finally:
            self.running -= 1


class Clock:
    def __init__(self):
        self.now = 1000.0

    def __call__(self):
        return self.now


class ProxyTests(unittest.IsolatedAsyncioTestCase):
    async def start(self, bahn_de=None, **options):
        self.bahn_de = bahn_de or FakeBahnDe()
        self.clock = Clock()
        self.proxy = proxy.Proxy(fetch=self.bahn_de, secret=SECRET, clock=self.clock, **options)
        self.client = TestClient(TestServer(proxy.make_app(self.proxy)))
        await self.client.start_server()
        self.addAsyncCleanup(self.client.close)

    async def get(self, path, token=WORKER_TOKEN):
        return await self.client.get(path, headers={proxy.TOKEN_HEADER: token} if token else {})

    async def test_passes_an_allowed_request_on_with_the_query_unchanged(self):
        await self.start()
        response = await self.get("/web/api/reiseloesung/fahrt?journeyId=2%7C%23VN%231%23&poly=false")
        self.assertEqual(response.status, 200)
        self.assertEqual(self.bahn_de.urls, ["https://www.bahn.de/web/api/reiseloesung/fahrt?journeyId=2%7C%23VN%231%23&poly=false"])
        self.assertEqual(response.headers["X-Proxy-Cache"], "MISS")
        self.assertEqual(response.headers["Cache-Control"], "public, max-age=30")

    async def test_only_the_workers_paths_and_only_get(self):
        await self.start()
        self.assertEqual((await self.get("/web/api/angebote/fahrplan")).status, 404)
        self.assertEqual((await self.get("/anything")).status, 404)
        self.assertEqual((await self.client.post(ORTE, headers={proxy.TOKEN_HEADER: WORKER_TOKEN})).status, 405)
        vbid = "/web/api/angebote/verbindung/0f0e0d0c-1111-2222-3333-444455556666"
        self.assertEqual((await self.get(vbid)).status, 200)
        self.assertEqual(len(self.bahn_de.urls), 1)

    async def test_only_the_app_with_a_token_from_the_workers(self):
        await self.start()
        self.assertEqual((await self.get(ORTE, token=None)).status, 401)
        self.assertEqual((await self.get(ORTE, token="x.y")).status, 401)
        self.assertEqual((await self.get(ORTE, token=WORKER_TOKEN[:-2] + "AA")).status, 401)
        self.assertEqual((await self.get(ORTE)).status, 200)
        self.assertEqual(self.bahn_de.urls, ["https://www.bahn.de" + ORTE])

    async def test_tokens_expire_and_must_be_access_tokens(self):
        self.assertIsNotNone(proxy.verify_token(WORKER_TOKEN, "a", SECRET, now=0))
        self.assertIsNone(proxy.verify_token(WORKER_TOKEN, "a", SECRET, now=4102444801))
        self.assertIsNone(proxy.verify_token(WORKER_TOKEN, "k", SECRET, now=0))
        self.assertIsNone(proxy.verify_token(WORKER_TOKEN, "a", "other-secret", now=0))

    async def test_caches_answers_for_their_route(self):
        await self.start()
        self.assertEqual((await self.get(ORTE)).headers["X-Proxy-Cache"], "MISS")
        second = await self.get(ORTE)
        self.assertEqual(second.headers["X-Proxy-Cache"], "HIT")
        self.assertEqual(len(self.bahn_de.urls), 1)
        self.clock.now += 86401
        await self.get(ORTE)
        self.assertEqual(len(self.bahn_de.urls), 2, "asked again once a day has passed")

    async def test_identical_requests_at_the_same_time_ask_bahn_de_once(self):
        await self.start(FakeBahnDe(delay=0.05))
        answers = await asyncio.gather(*(self.get(ORTE) for _ in range(5)))
        self.assertEqual([a.status for a in answers], [200] * 5)
        self.assertEqual(len(self.bahn_de.urls), 1)

    async def test_a_block_pauses_bahn_de_starts_a_new_session_and_isnt_cached(self):
        await self.start(FakeBahnDe(status=452))
        first = await self.get(ORTE)
        self.assertEqual(first.status, 452)
        self.assertEqual(first.headers["Cache-Control"], "no-store")
        self.assertEqual(self.bahn_de.resets, 1)
        paused = await self.get("/web/api/reiseloesung/abfahrten?ortExtId=8011160")
        self.assertEqual(paused.status, 503)
        self.assertEqual(len(self.bahn_de.urls), 1, "nothing goes to bahn.de while paused")
        self.assertTrue((await (await self.client.get("/health")).json())["paused"])
        self.clock.now += 61
        self.bahn_de.status = 200
        self.assertEqual((await self.get(ORTE)).status, 200)

    async def test_refusals_soon_after_a_pause_pause_longer_up_to_the_limit(self):
        await self.start(FakeBahnDe(status=403), first_pause=60, block_pause=200)
        pauses = []
        for _ in range(4):
            await self.get(ORTE)
            pauses.append(self.proxy.paused_until - self.clock.now)
            self.clock.now = self.proxy.paused_until + 1
        self.assertEqual(pauses, [60, 120, 200, 200])
        self.clock.now += proxy.STRIKE_WINDOW
        await self.get(ORTE)
        self.assertEqual(self.proxy.paused_until - self.clock.now, 60, "a refusal long after starts over")

    async def test_only_a_few_requests_go_to_bahn_de_at_once(self):
        await self.start(FakeBahnDe(delay=0.02), max_parallel=2)
        answers = await asyncio.gather(*(self.get(f"{ORTE}&n={n}") for n in range(8)))
        self.assertEqual([a.status for a in answers], [200] * 8)
        self.assertEqual(self.bahn_de.most_running, 2)

    async def test_a_refused_burst_pauses_once_and_holds_back_the_waiting_requests(self):
        await self.start(FakeBahnDe(status=403, delay=0.02), max_parallel=2)
        answers = await asyncio.gather(*(self.get(f"{ORTE}&n={n}") for n in range(8)))
        self.assertEqual(sorted(a.status for a in answers), [403, 403] + [503] * 6)
        self.assertEqual(len(self.bahn_de.urls), 2, "the waiting requests never went out")
        self.assertEqual(self.bahn_de.resets, 1)
        self.assertEqual(self.proxy.paused_until - self.clock.now, 60)

    async def test_a_cached_answer_is_still_served_while_paused(self):
        await self.start()
        await self.get(ORTE)
        self.proxy.paused_until = self.clock.now + 600
        self.assertEqual((await self.get(ORTE)).status, 200)

    async def test_rate_limits_each_install(self):
        await self.start(rate_limit=2)
        self.assertEqual((await self.get(ORTE)).status, 200)
        self.assertEqual((await self.get(ORTE)).status, 200)
        self.assertEqual((await self.get(ORTE)).status, 429)
        self.clock.now += 61
        self.assertEqual((await self.get(ORTE)).status, 200)

    async def test_unreachable_bahn_de_is_a_502(self):
        async def failing(url):
            raise ConnectionError("down")

        await self.start(failing)
        self.assertEqual((await self.get(ORTE)).status, 502)


class FakeSession:
    """curl_cffi session stand-in: records each GET with its headers."""

    def __init__(self, log):
        self.log = log
        self.closed = False

    async def get(self, url, headers=None):
        self.log.append((self, url, headers or {}))
        await asyncio.sleep(0.01)
        return type("Response", (), {"status_code": 200, "content": b"{}", "headers": {}})()

    async def close(self):
        self.closed = True


class BrowserFetchTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.log = []
        self.clock = Clock()
        self.fetch = proxy.BrowserFetch("safari", make_session=lambda: FakeSession(self.log), clock=self.clock)

    async def test_a_new_session_opens_the_page_first_then_asks_like_the_page(self):
        await asyncio.gather(self.fetch(proxy.UPSTREAM + "a"), self.fetch(proxy.UPSTREAM + "b"))
        urls = [url for _, url, _ in self.log]
        self.assertEqual(urls[0], proxy.PAGE)
        self.assertEqual(urls.count(proxy.PAGE), 1, "requests during the start share its page load")
        self.assertEqual(sorted(urls[1:]), [proxy.UPSTREAM + "a", proxy.UPSTREAM + "b"])
        headers = self.log[1][2]
        self.assertEqual(headers["Sec-Fetch-Mode"], "cors")
        self.assertEqual(headers["Sec-Fetch-Site"], "same-origin")
        self.assertEqual(headers["Accept-Encoding"], "gzip, br")
        self.assertEqual(self.log[0][2]["Accept-Encoding"], "gzip, br")

    async def test_reset_and_age_start_a_new_session(self):
        await self.fetch(proxy.UPSTREAM + "a")
        first = self.log[0][0]
        self.fetch.reset()
        await self.fetch(proxy.UPSTREAM + "b")
        second = self.log[-1][0]
        self.assertIsNot(first, second)
        self.clock.now += proxy.SESSION_MAX_AGE + 1
        await self.fetch(proxy.UPSTREAM + "c")
        self.assertIsNot(self.log[-1][0], second)
        self.assertEqual([url for _, url, _ in self.log].count(proxy.PAGE), 3)


if __name__ == "__main__":
    unittest.main()
