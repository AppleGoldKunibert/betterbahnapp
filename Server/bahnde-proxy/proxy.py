"""bahn.de proxy with a browser's TLS fingerprint (#342).

bahn.de's bot protection (Akamai) refuses every request whose TLS/HTTP2 handshake isn't a browser's
(403/452 OPS_BLOCKED), whatever its address, headers or cookies; Cloudflare Workers can't change theirs.
This server asks bahn.de with curl_cffi, which makes the handshake of a real browser (`IMPERSONATE`, Safari
by default). It mirrors the Worker `betterbahn2` (Cloudflare/bahnde-proxy): the same `/web/api/…` paths,
GET only, and only for the app (the same App Attest tokens, signed with `TOKEN_SECRET`).

bahn.de tolerates this as long as the traffic stays small, so the server keeps it small:
- answers are cached (seconds for live data, a day for stations), and identical requests running at the
  same time share one upstream request;
- each app install may make `RATE_LIMIT` requests a minute;
- at most `MAX_PARALLEL` requests go to bahn.de at the same time; a burst of parallel requests got the
  server refused (403) while single ones from the same address went through;
- requests to bahn.de start at least `MIN_INTERVAL` seconds apart: ten departure boards within a second got
  the server refused (429) although no more than four ran at once;
- after bahn.de refused a request (403, 429, 452), the server starts a new session (bahn.de's bot cookies
  of the old one may be flagged) and nothing goes there for a while: `FIRST_PAUSE` seconds, doubling with
  each refusal soon after the last one up to `BLOCK_PAUSE`. Meanwhile the app gets 503 and says the live
  data is missing. Requests already running finish on the old session.

Environment: TOKEN_SECRET (required, same as in the Workers), PORT (8080), IMPERSONATE (safari),
FIRST_PAUSE (60), BLOCK_PAUSE (600), MAX_PARALLEL (4), MIN_INTERVAL (0.25), RATE_LIMIT (120),
ALLOW_UNATTESTED ("true" lets requests without a token through, for testing only).
"""

import asyncio
import base64
import hashlib
import hmac
import json
import logging
import os
import re
import time
import uuid
from collections import OrderedDict
from dataclasses import dataclass, field

from aiohttp import web

UPSTREAM = "https://www.bahn.de/web/api/"
TOKEN_HEADER = "X-BetterBahn-Token"

# Allowed paths (relative to /web/api/) and how long a successful answer is cached, in seconds.
ROUTES = {
    "reiseloesung/orte": 86400,
    "reiseloesung/orte/nearby": 86400,
    "reiseloesung/abfahrten": 30,
    "reiseloesung/ankuenfte": 30,
    "reiseloesung/fahrt": 30,
    "reisebegleitung/wagenreihung/vehicle-sequence": 120,
}
# A connection shared from the DB Navigator or bahn.de (the "Verbindung ansehen" link's vbid).
PATTERN_ROUTES = [
    (re.compile(r"^angebote/verbindung/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"), 3600),
]
# bahn.de refusing us: leave it alone for a while.
BLOCK_STATUSES = {403, 429, 452}
MAX_CACHE_ENTRIES = 5000
MAX_QUERY_LENGTH = 2000
UPSTREAM_TIMEOUT = 10
# A refusal within this many seconds after the last pause ended doubles the next pause.
STRIKE_WINDOW = 1800
# bahn.de's search page, which a session loads first, and how long a session is kept (its cookies expire).
PAGE = "https://www.bahn.de/buchung/fahrplan/suche"
SESSION_MAX_AGE = 3600
# What DB's RIS API team asks clients to accept. With the browser's "gzip, deflate, br" bahn.de held every
# answer back for 1-3 s (measured 2026-10-16: a coach sequence in 3.3 s, with "gzip, br" in 0.23 s).
ACCEPT_ENCODING = "gzip, br"

log = logging.getLogger("bahnde-proxy")


def route_ttl(path):
    """Cache time of an allowed path relative to /web/api/, or None."""
    if path in ROUTES:
        return ROUTES[path]
    return next((ttl for pattern, ttl in PATTERN_ROUTES if pattern.match(path)), None)


# MARK: - App Attest tokens (as verifyToken in Cloudflare/shared/appattest.mjs)


def _from_base64url(text):
    return base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))


def verify_token(token, kind, secret, now=None):
    """The payload of an unexpired token of `kind` signed with `secret`, or None."""
    if not isinstance(token, str) or len(token) > 4096 or not secret:
        return None
    parts = token.split(".")
    if len(parts) != 2:
        return None
    try:
        expected = hmac.new(secret.encode(), parts[0].encode(), hashlib.sha256).digest()
        if not hmac.compare_digest(expected, _from_base64url(parts[1])):
            return None
        payload = json.loads(_from_base64url(parts[0]))
    except (ValueError, TypeError):
        return None
    if not isinstance(payload, dict) or payload.get("t") != kind:
        return None
    exp = payload.get("exp")
    if exp is not None and not exp > (time.time() if now is None else now):
        return None
    return payload


# MARK: - Proxy


@dataclass
class Answer:
    status: int
    body: bytes
    content_type: str = "application/json; charset=utf-8"


@dataclass
class Proxy:
    """The proxy's state; `fetch(url) -> Answer` asks bahn.de (replaced in tests), `fetch.reset()`, when
    there, starts a new session."""

    fetch: object
    secret: str
    allow_unattested: bool = False
    first_pause: float = 60
    block_pause: float = 600
    max_parallel: int = 4
    # Seconds between the starts of two requests to bahn.de (`MIN_INTERVAL`, 0.25 in production).
    min_interval: float = 0
    rate_limit: int = 120
    clock: object = time.monotonic
    sleep: object = asyncio.sleep
    cache: OrderedDict = field(default_factory=OrderedDict)
    running: dict = field(default_factory=dict)
    paused_until: float = 0
    last_pause: float = 0
    next_start: float = 0
    requests: dict = field(default_factory=dict)
    slots: asyncio.Semaphore = None

    def __post_init__(self):
        self.slots = asyncio.Semaphore(self.max_parallel)

    def authorized(self, request):
        """The key the request is rate limited by, or None when it isn't allowed."""
        token = request.headers.get(TOKEN_HEADER)
        if token:
            claims = verify_token(token, "a", self.secret)
            return f"kid:{claims.get('kid')}" if claims else None
        return "unattested" if self.allow_unattested else None

    def within_rate(self, key):
        """Counts a request of `key`; False once it made `rate_limit` in the last minute."""
        now = self.clock()
        recent = [t for t in self.requests.get(key, []) if now - t < 60]
        if len(recent) >= self.rate_limit:
            self.requests[key] = recent
            return False
        recent.append(now)
        self.requests[key] = recent
        if len(self.requests) > 10000:
            self.requests = {k: v for k, v in self.requests.items() if v and now - v[-1] < 60}
        return True

    def cached(self, url):
        entry = self.cache.get(url)
        if entry is None:
            return None
        expires, answer = entry
        if expires <= self.clock():
            del self.cache[url]
            return None
        self.cache.move_to_end(url)
        return answer

    def store(self, url, answer, ttl):
        self.cache[url] = (self.clock() + ttl, answer)
        self.cache.move_to_end(url)
        while len(self.cache) > MAX_CACHE_ENTRIES:
            self.cache.popitem(last=False)

    async def upstream(self, url, ttl):
        """bahn.de's answer for `url`: cached, shared with a request already running, or asked now."""
        hit = self.cached(url)
        if hit is not None:
            return hit, True
        if url in self.running:
            return await asyncio.shield(self.running[url]), False
        task = asyncio.ensure_future(self._ask(url, ttl))
        self.running[url] = task
        try:
            return await asyncio.shield(task), False
        finally:
            self.running.pop(url, None)

    async def _ask(self, url, ttl):
        async with self.slots:
            await self._wait_turn()
            if self.paused:
                # Refused while this request waited for a slot or its turn.
                return paused_answer()
            answer = await self.fetch(url)
        if 200 <= answer.status < 300:
            self.store(url, answer, ttl)
        elif answer.status in BLOCK_STATUSES and not self.paused:
            # Requests already running when bahn.de refused come back refused too; one pause covers them.
            self.block(answer.status, url)
        return answer

    async def _wait_turn(self):
        """Starts requests to bahn.de `min_interval` apart, so a burst reaches it spread out."""
        now = self.clock()
        start = max(now, self.next_start)
        self.next_start = start + self.min_interval
        if start > now:
            await self.sleep(start - now)

    def block(self, status, url):
        now = self.clock()
        recent = self.last_pause and now - self.paused_until < STRIKE_WINDOW
        self.last_pause = min(self.last_pause * 2, self.block_pause) if recent else min(self.first_pause, self.block_pause)
        self.paused_until = now + self.last_pause
        reset = getattr(self.fetch, "reset", None)
        if reset:
            reset()
        path = url[len(UPSTREAM):].split("?")[0]
        log.warning("bahn.de answered %s to %s, new session, pausing for %ss", status, path, int(self.last_pause))

    @property
    def paused(self):
        return self.paused_until > self.clock()

    async def handle(self, request):
        if request.path == "/health":
            return json_response(200, {"ok": True, "paused": self.paused})
        if not request.path.startswith("/web/api/"):
            return json_response(404, {"error": "not_found"})
        path = request.path[len("/web/api/"):]
        ttl = route_ttl(path)
        if ttl is None:
            return json_response(404, {"error": "not_found"})
        if request.method != "GET":
            return json_response(405, {"error": "method_not_allowed"}, {"Allow": "GET"})
        key = self.authorized(request)
        if key is None:
            return json_response(401, {"error": "unauthorized"})
        if not self.within_rate(key):
            return json_response(429, {"error": "rate_limited"})
        # The query exactly as sent, e.g. "%23" in journey IDs.
        query = request.rel_url.raw_query_string
        if len(query) > MAX_QUERY_LENGTH:
            return json_response(414, {"error": "too_long"})
        url = UPSTREAM + path + ("?" + query if query else "")

        hit = self.cached(url)
        if hit is None and self.paused:
            # The app says the live data is missing; nothing goes to bahn.de until the pause is over.
            return json_response(503, {"error": "paused"}, {"Retry-After": str(int(self.paused_until - self.clock()) + 1)})
        try:
            answer, from_cache = (hit, True) if hit is not None else await self.upstream(url, ttl)
        except Exception as error:  # noqa: BLE001 - any failure to reach bahn.de is a 502 for the app
            log.warning("bahn.de unreachable: %s", type(error).__name__)
            return json_response(502, {"error": "upstream_unreachable"})
        ok = 200 <= answer.status < 300
        return web.Response(status=answer.status, body=answer.body, headers={
            "Content-Type": answer.content_type,
            "Cache-Control": f"public, max-age={ttl}" if ok else "no-store",
            "X-Proxy-Cache": "HIT" if from_cache else "MISS",
        })


def paused_answer():
    return Answer(503, json.dumps({"error": "paused"}).encode())


def json_response(status, body, extra=None):
    return web.Response(status=status, text=json.dumps(body), headers={
        "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store", **(extra or {})})


# MARK: - bahn.de with a browser's handshake


def timings(response):
    """Where a request's time went (curl's own clock, cumulative): name lookup, connect, TLS, first byte.
    Zero for steps a reused connection skipped."""
    infos = {getattr(key, "name", str(key)): value for key, value in (getattr(response, "infos", None) or {}).items()}
    steps = [("dns", "NAMELOOKUP_TIME"), ("connect", "CONNECT_TIME"), ("tls", "APPCONNECT_TIME"),
             ("first byte", "STARTTRANSFER_TIME")]
    parts = [f"{label} {infos[key] * 1000:.0f}" for label, key in steps if key in infos]
    return f" ({', '.join(parts)} ms)" if parts else ""


class BrowserFetch:
    """`fetch` asking bahn.de with curl_cffi, which makes the TLS/HTTP2 handshake of the browser
    `impersonate` and sends its User-Agent. Like bahn.de's own page: a new session first loads the search
    page (which sets bahn.de's cookies), then asks the API with the headers of the page's background
    requests. Sessions are renewed after `SESSION_MAX_AGE`; `reset()` drops the session and its cookies at
    once, so the next request starts a new one, while the requests still running on the old one finish there
    (closing it cut them off: curl reported status 0, which Tailscale Funnel turned into a 502 for the app).
    `make_session` is replaced in tests."""

    def __init__(self, impersonate, make_session=None, clock=time.monotonic):
        self.impersonate = impersonate
        self.make_session = make_session or self._curl_session
        self.clock = clock
        self.session = None
        self.started = 0
        self.starting = None
        # Requests running per session (by id); a session `reset()` replaced is closed after its last one.
        self.running = {}

    def _curl_session(self):
        from curl_cffi.const import CurlInfo
        from curl_cffi.requests import AsyncSession

        return AsyncSession(impersonate=self.impersonate, timeout=UPSTREAM_TIMEOUT, curl_infos=[
            CurlInfo.NAMELOOKUP_TIME, CurlInfo.CONNECT_TIME, CurlInfo.APPCONNECT_TIME, CurlInfo.STARTTRANSFER_TIME])

    def reset(self):
        old, self.session = self.session, None
        if old is not None:
            self._close_when_done(old)

    def _close_when_done(self, session):
        if session is not self.session and not self.running.get(id(session)):
            self.running.pop(id(session), None)
            asyncio.ensure_future(session.close())

    async def _session(self):
        if self.session is not None and self.clock() - self.started > SESSION_MAX_AGE:
            self.reset()
        if self.session is not None:
            return self.session
        # Requests arriving while a session starts share its page load.
        if self.starting is None:
            self.starting = asyncio.ensure_future(self._start())
        try:
            return await asyncio.shield(self.starting)
        finally:
            self.starting = None

    async def _start(self):
        session = self.make_session()
        began = time.perf_counter()
        try:
            # The page a visitor opens first; its answer sets bahn.de's cookies (bm_sz, ak_bmsc, _abck).
            await session.get(PAGE, headers={"Accept-Encoding": ACCEPT_ENCODING})
            log.info("bahn.de page loaded in %d ms", (time.perf_counter() - began) * 1000)
        except Exception as error:  # noqa: BLE001 - the API request itself still decides
            log.warning("bahn.de page unreachable: %s", type(error).__name__)
        self.session, self.started = session, self.clock()
        return session

    async def __call__(self, url):
        session = await self._session()
        self.running[id(session)] = self.running.get(id(session), 0) + 1
        began = time.perf_counter()
        try:
            response = await session.get(url, headers={
                "Accept": "application/json",
                "Accept-Encoding": ACCEPT_ENCODING,
                "Accept-Language": "de",
                "Referer": PAGE,
                "Sec-Fetch-Site": "same-origin",
                "Sec-Fetch-Mode": "cors",
                "Sec-Fetch-Dest": "empty",
                "x-correlation-id": f"{uuid.uuid4()}_{uuid.uuid4()}",
            })
        finally:
            self.running[id(session)] -= 1
            self._close_when_done(session)
        log.info("bahn.de %s %s in %d ms%s", response.status_code, url[len(UPSTREAM):].split("?")[0],
                 (time.perf_counter() - began) * 1000, timings(response))
        if not 100 <= response.status_code < 600:
            # No answer at all (status 0): a 502 with a body the app can read, not an invalid status line.
            raise ConnectionError(f"no answer (status {response.status_code})")
        return Answer(response.status_code, response.content,
                      response.headers.get("Content-Type") or "application/json; charset=utf-8")


def make_app(proxy):
    app = web.Application(client_max_size=4096)
    app.router.add_route("*", "/{tail:.*}", proxy.handle)
    return app


def main():
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    # aiohttp's access log would record client addresses; the proxy keeps none.
    logging.getLogger("aiohttp.access").setLevel(logging.WARNING)
    secret = os.environ.get("TOKEN_SECRET", "")
    allow_unattested = os.environ.get("ALLOW_UNATTESTED") == "true"
    if not secret and not allow_unattested:
        raise SystemExit("TOKEN_SECRET is missing (the same value as in the Cloudflare Workers).")
    proxy = Proxy(
        fetch=BrowserFetch(os.environ.get("IMPERSONATE", "safari")),
        secret=secret,
        allow_unattested=allow_unattested,
        first_pause=float(os.environ.get("FIRST_PAUSE", "60")),
        block_pause=float(os.environ.get("BLOCK_PAUSE", "600")),
        max_parallel=int(os.environ.get("MAX_PARALLEL", "4")),
        min_interval=float(os.environ.get("MIN_INTERVAL", "0.25")),
        rate_limit=int(os.environ.get("RATE_LIMIT", "120")),
    )
    web.run_app(make_app(proxy), port=int(os.environ.get("PORT", "8080")), access_log=None)


if __name__ == "__main__":
    main()
