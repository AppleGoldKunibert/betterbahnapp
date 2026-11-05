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

It also passes the app's requests for DB's official RIS::Journeys (DB API Marketplace) on, with the
key the app mustn't carry: `/db/apis/ris-journeys/v2/find` and `/{journeyID}`, the same paths as on
apis.deutschebahn.com. That is a second `Proxy` with its own cache, rate and pauses, so bahn.de refusing
the server doesn't stop it; it only pauses after a 429.

Coach sequences ("Wagenreihung", `vehicle-sequence`) are asked at DB Regio's Wi-Fi portal first
(`RegioSequences`): the same RIS::Transports data bahn.de shows, translated into bahn.de's answer, so the app
doesn't notice. A refusal there is tried 10 times; then bahn.de answers for 5 minutes, and a second refusal
right after that turns the portal off until the server restarts. Refusals, and coach sequences the portal
doesn't have for a train it should have, go to `REGIO_LOG`.

Environment: TOKEN_SECRET (required, same as in the Workers), PORT (8080), IMPERSONATE (safari),
FIRST_PAUSE (60), BLOCK_PAUSE (600), MAX_PARALLEL (4), MIN_INTERVAL (0.25), RATE_LIMIT (120),
ALLOW_UNATTESTED ("true" lets requests without a token through, for testing only),
DB_CLIENT_ID and DB_API_KEY (DB API Marketplace; without them the RIS paths answer 404),
REGIO ("false" asks bahn.de for coach sequences only), REGIO_LOG (logs/regio.log).
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
from datetime import datetime, timezone

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

# DB's RIS::Journeys, below the same path as on apis.deutschebahn.com.
RIS_PREFIX = "/db/apis/ris-journeys/v2/"
RIS_UPSTREAM = "https://apis.deutschebahn.com/db/apis/ris-journeys/v2/"
RIS_ACCEPT = "application/vnd.de.db.ris+json"
# A run's ID: its day and a UUID, "20261103-c5ed6631-9860-3f62-aa16-50637daedbaf".
RIS_JOURNEY_ID = re.compile(r"^\d{8}-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
# Only a rate limit pauses RIS; a refused key (401) would not get better by waiting.
RIS_BLOCK_STATUSES = {429}
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


def ris_route_ttl(path):
    """Cache time of an allowed path relative to RIS_PREFIX, or None: the runs of a number, or one run."""
    if path == "find":
        return 300
    return 30 if RIS_JOURNEY_ID.match(path) else None


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
    # Where the app's paths start, what they are asked at, which are allowed (path -> cache seconds or None)
    # and which answers pause asking: bahn.de's by default, RIS::Journeys' for `ris_proxy`.
    prefix: str = "/web/api/"
    upstream_base: str = UPSTREAM
    ttl_for: object = route_ttl
    block_statuses: frozenset = frozenset(BLOCK_STATUSES)
    name: str = "bahn.de"
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
        elif answer.status in self.block_statuses and not self.paused:
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
        path = url[len(self.upstream_base):].split("?")[0]
        log.warning("%s answered %s to %s, new session, pausing for %ss", self.name, status, path, int(self.last_pause))

    @property
    def paused(self):
        return self.paused_until > self.clock()

    async def handle(self, request, counted=False):
        """`counted`: the request already counted towards its install's rate (`RegioSequences`)."""
        if request.path == "/health":
            return json_response(200, {"ok": True, "paused": self.paused})
        if not request.path.startswith(self.prefix):
            return json_response(404, {"error": "not_found"})
        path = request.path[len(self.prefix):]
        ttl = self.ttl_for(path)
        if ttl is None:
            return json_response(404, {"error": "not_found"})
        if request.method != "GET":
            return json_response(405, {"error": "method_not_allowed"}, {"Allow": "GET"})
        key = self.authorized(request)
        if key is None:
            return json_response(401, {"error": "unauthorized"})
        if not counted and not self.within_rate(key):
            return json_response(429, {"error": "rate_limited"})
        # The query exactly as sent, e.g. "%23" in journey IDs.
        query = request.rel_url.raw_query_string
        if len(query) > MAX_QUERY_LENGTH:
            return json_response(414, {"error": "too_long"})
        url = self.upstream_base + path + ("?" + query if query else "")

        hit = self.cached(url)
        if hit is None and self.paused:
            # The app says the live data is missing; nothing goes to bahn.de until the pause is over.
            return json_response(503, {"error": "paused"}, {"Retry-After": str(int(self.paused_until - self.clock()) + 1)})
        try:
            answer, from_cache = (hit, True) if hit is not None else await self.upstream(url, ttl)
        except Exception as error:  # noqa: BLE001 - any failure to reach bahn.de is a 502 for the app
            log.warning("%s unreachable: %s", self.name, type(error).__name__)
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


class RISFetch:
    """`fetch` asking DB's API Marketplace with the server's key; no browser needed there."""

    def __init__(self, client_id, api_key):
        self.headers = {"DB-Client-Id": client_id, "DB-Api-Key": api_key, "Accept": RIS_ACCEPT,
                        "Accept-Encoding": "gzip"}
        self.session = None

    async def __call__(self, url):
        import aiohttp

        if self.session is None:
            self.session = aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=UPSTREAM_TIMEOUT))
        began = time.perf_counter()
        async with self.session.get(url, headers=self.headers) as response:
            body = await response.read()
            log.info("RIS %s %s in %d ms", response.status, url[len(RIS_UPSTREAM):].split("?")[0][:8],
                     (time.perf_counter() - began) * 1000)
            return Answer(response.status, body, response.headers.get("Content-Type") or "application/json; charset=utf-8")


# MARK: - Coach sequences from DB Regio's Wi-Fi portal

SEQUENCE_PATH = "reisebegleitung/wagenreihung/vehicle-sequence"
REGIO_PAGE = "https://wifi-landingpage.dbregio.de/"
REGIO_UPSTREAM = "https://wifi-landingpage.dbregio.de/api/transports/vehicle-sequences/departures/unmatched"
REGIO_CSRF = re.compile(r'name="csrf-token" content="([^"]+)"')
# The portal refusing us (or no CSRF token): tried again, then paused, then off.
REGIO_BLOCK_STATUSES = {401, 403, 419, 429, 452}
REGIO_ATTEMPTS = 10
REGIO_RETRY_DELAY = 0.3
REGIO_PAUSE = 300
# A coach sequence the portal should have: a train (not S-Bahn, bus, tram, subway) leaving a German station
# (EVA numbers 80…) within this many seconds. It is asked only where the train departs, never at its last stop.
REGIO_EXPECTED_WITHIN = 20 * 3600
REGIO_NOT_TRAINS = {"S", "BUS", "STR", "TRAM", "U", "SEV", "BSV", "FAE", "SCH"}
# A run the portal had no coach sequence for, so the app's next look doesn't ask again right away.
REGIO_MISSING_TTL = 60
REGIO_SESSION_MAX_AGE = 1800
REGIO_USER_AGENT = ("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 "
                    "(KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1")


class RegioBlocked(Exception):
    """The portal refused us; `reason` says how (status or a missing CSRF token)."""

    def __init__(self, reason):
        super().__init__(reason)
        self.reason = reason


def regio_url(query):
    """The portal's request for bahn.de's coach-sequence query (`category`, `number`, `evaNumber`, `date`,
    `time` as the app sends it), or None when one is missing."""
    try:
        when = parse_time(query["time"])
        params = {"category": query["category"], "journeyNumber": query["number"], "evaNumber": query["evaNumber"],
                  "date": query["date"], "timeSchedule": when.strftime("%Y-%m-%dT%H:%M:%SZ"),
                  "includeAmenities": "true", "includePosition": "true"}
    except (KeyError, ValueError):
        return None
    from urllib.parse import urlencode

    return REGIO_UPSTREAM + "?" + urlencode(params)


def parse_time(text):
    """The app's `time` (UTC, "2026-11-05T14:45:00.000Z")."""
    return datetime.fromisoformat(text.replace("Z", "+00:00")).astimezone(timezone.utc)


def bahn_de_sequence(regio):
    """The portal's coach sequence (RIS::Transports) in bahn.de's shape. The portal has every field bahn.de
    has, with a few more kept as they are; only the platform and each group's train sit elsewhere."""
    answer = {key: value for key, value in regio.items() if key not in ("platform", "groups")}
    platform = regio.get("platform") or {}
    if "platform" in platform:
        answer["departurePlatform"] = platform["platform"]
    if "platformSchedule" in platform:
        answer["departurePlatformSchedule"] = platform["platformSchedule"]
    details = platform.get("details")
    if details:
        answer["platform"] = {"name": details.get("name"), "start": details.get("start"), "end": details.get("end"),
                              "sectors": [{key: sector.get(key) for key in ("name", "start", "end")}
                                          for sector in details.get("sectors") or []]}
    groups = []
    for group in regio.get("groups") or []:
        group = dict(group)
        relation = group.get("journeyRelation") or {}
        destination = group.get("destination") or {}
        group["transport"] = {"category": relation.get("startCategory"), "number": relation.get("startJourneyNumber"),
                              "destination": {"name": destination.get("name")}, "journeyID": group.get("journeyID")}
        groups.append(group)
    answer["groups"] = groups
    return answer


def expected_sequence(query, now):
    """Whether the portal should have had this coach sequence (see REGIO_EXPECTED_WITHIN)."""
    try:
        departure = parse_time(query["time"])
    except (KeyError, ValueError):
        return False
    ahead = (departure - now).total_seconds()
    return (0 <= ahead <= REGIO_EXPECTED_WITHIN and query.get("evaNumber", "").startswith("80")
            and query.get("category", "").upper() not in REGIO_NOT_TRAINS)


class RegioFetch:
    """`fetch` asking the portal like its page does: the page first (cookie `__Host-csrf` and the meta tag
    `csrf-token`), then the API with that token as `Csrf-Token`. `reset()` starts over with a new page."""

    def __init__(self, clock=time.monotonic):
        self.clock = clock
        self.session = None
        self.token = None
        self.started = 0

    def reset(self):
        session, self.session, self.token = self.session, None, None
        if session is not None:
            asyncio.ensure_future(session.close())

    async def _start(self):
        import aiohttp

        session = aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=UPSTREAM_TIMEOUT),
                                        headers={"User-Agent": REGIO_USER_AGENT, "Accept-Language": "de"})
        async with session.get(REGIO_PAGE) as response:
            page = await response.text()
            match = REGIO_CSRF.search(page) if response.status == 200 else None
        if not match:
            await session.close()
            raise RegioBlocked(f"page {response.status}, no CSRF token")
        self.session, self.token, self.started = session, match.group(1), self.clock()

    async def __call__(self, url):
        if self.session is None or self.clock() - self.started > REGIO_SESSION_MAX_AGE:
            self.reset()
            await self._start()
        began = time.perf_counter()
        async with self.session.get(url, headers={"Csrf-Token": self.token, "Accept": "application/json"}) as response:
            body = await response.read()
            log.info("Regio %s %s in %d ms", response.status, url.split("journeyNumber=")[-1].split("&")[0],
                     (time.perf_counter() - began) * 1000)
            return Answer(response.status, body, response.headers.get("Content-Type") or "application/json; charset=utf-8")


@dataclass
class RegioSequences:
    """Coach sequences from DB Regio's Wi-Fi portal before bahn.de (`proxy`):
    - a refusal (REGIO_BLOCK_STATUSES or no CSRF token) is tried again, up to REGIO_ATTEMPTS times in all,
      each with a new page; meanwhile other requests go to bahn.de;
    - all refused: bahn.de answers for `pause` seconds, then the portal is asked again; refused once more
      right then (all attempts), the portal stays off until the server restarts;
    - a 404 is the answer (bahn.de has the same data, so it has none either): the app gets 404, and when the
      portal should have had it (`expected_sequence`) a line goes to the log;
    - any other failure (5xx, unreachable, an answer that isn't JSON) goes to bahn.de for that request.
    Every refusal is written to `log_path` with time, answer and request."""

    fetch: object
    proxy: object
    log_path: str = "logs/regio.log"
    attempts: int = REGIO_ATTEMPTS
    retry_delay: float = REGIO_RETRY_DELAY
    pause: float = REGIO_PAUSE
    clock: object = time.monotonic
    now: object = lambda: datetime.now(timezone.utc)  # noqa: E731 - replaced in tests
    sleep: object = asyncio.sleep
    cache: OrderedDict = field(default_factory=OrderedDict)
    paused_until: float = 0
    # Refused after a pause: off until the server restarts.
    off: bool = False
    # A pause ended and the next request decides whether the portal is back.
    on_probation: bool = False
    trying: bool = False
    missing_logged: set = field(default_factory=set)

    def write_log(self, kind, text):
        line = f"{self.now().strftime('%Y-%m-%d %H:%M:%S')} UTC {kind} {text}\n"
        try:
            directory = os.path.dirname(self.log_path)
            if directory:
                os.makedirs(directory, exist_ok=True)
            with open(self.log_path, "a", encoding="utf-8") as file:
                file.write(line)
        except OSError as error:
            log.warning("Regio log not written: %s", error)

    @property
    def usable(self):
        return not self.off and not self.trying and self.paused_until <= self.clock()

    async def handle(self, request):
        """The coach sequence from the portal, or bahn.de's (`proxy.handle`) when the portal can't answer."""
        query = dict(request.rel_url.query)
        url = regio_url(query)
        hit = self.cached(self.query_key(query))
        if request.method != "GET" or url is None or len(request.rel_url.raw_query_string) > MAX_QUERY_LENGTH \
                or (hit is None and not self.usable):
            return await self.proxy.handle(request)
        key = self.proxy.authorized(request)
        if key is None:
            return json_response(401, {"error": "unauthorized"})
        if not self.proxy.within_rate(key):
            return json_response(429, {"error": "rate_limited"})
        if hit is None:
            hit = await self.ask(url, query)
        if hit is None:
            return await self.proxy.handle(request, counted=True)
        status, body = hit
        ok = status == 200
        return web.Response(status=status, body=body, headers={
            "Content-Type": "application/json; charset=utf-8",
            "Cache-Control": f"public, max-age={ROUTES[SEQUENCE_PATH]}" if ok else "no-store",
            "X-Proxy-Source": "regio",
        })

    def cached(self, query):
        entry = self.cache.get(query)
        if entry is None:
            return None
        expires, answer = entry
        if expires <= self.clock():
            del self.cache[query]
            return None
        return answer

    def store(self, query, answer, ttl):
        self.cache[query] = (self.clock() + ttl, answer)
        self.cache.move_to_end(query)
        while len(self.cache) > MAX_CACHE_ENTRIES:
            self.cache.popitem(last=False)

    async def ask(self, url, query):
        """(status, body) in bahn.de's shape, or None for bahn.de to answer."""
        try:
            for attempt in range(1, self.attempts + 1):
                try:
                    answer = await self.fetch(url)
                except RegioBlocked as blocked:
                    reason = blocked.reason
                except Exception as error:  # noqa: BLE001 - unreachable: bahn.de answers this one
                    log.warning("Regio unreachable: %s", type(error).__name__)
                    return None
                else:
                    if answer.status not in REGIO_BLOCK_STATUSES:
                        self.on_probation = False
                        return self.answered(answer, url, query)
                    reason = f"{answer.status} {answer.body[:120].decode('utf-8', 'replace')}"
                # While this request tries again, the others go to bahn.de.
                self.trying = True
                self.write_log("BLOCK", f"attempt {attempt}/{self.attempts}: {reason} ({self.describe(query)})")
                reset = getattr(self.fetch, "reset", None)
                if reset:
                    reset()
                if attempt < self.attempts:
                    await self.sleep(self.retry_delay * attempt)
            if self.on_probation:
                self.off = True
                self.write_log("OFF", "refused again after the pause: bahn.de only until the server restarts")
                log.warning("Regio refused again after its pause: off until restart")
            else:
                self.paused_until = self.clock() + self.pause
                self.on_probation = True
                self.write_log("PAUSE", f"refused {self.attempts} times: bahn.de for {int(self.pause)} s")
                log.warning("Regio refused %d times: bahn.de for %ds", self.attempts, self.pause)
            return None
        finally:
            self.trying = False

    def answered(self, answer, url, query):
        if answer.status == 404:
            if expected_sequence(query, self.now()):
                seen = (query.get("category"), query.get("number"), query.get("date"), query.get("evaNumber"))
                if seen not in self.missing_logged:
                    self.missing_logged.add(seen)
                    if len(self.missing_logged) > 10000:
                        self.missing_logged.clear()
                    self.write_log("MISSING", f"no coach sequence for {self.describe(query)}")
            result = (404, json.dumps({"error": "not_found"}).encode())
            self.store(self.query_key(query), result, REGIO_MISSING_TTL)
            return result
        if answer.status != 200:
            log.warning("Regio answered %s", answer.status)
            return None
        try:
            body = json.dumps(bahn_de_sequence(json.loads(answer.body)), ensure_ascii=False).encode()
        except (ValueError, TypeError, AttributeError):
            log.warning("Regio answer isn't a coach sequence")
            return None
        result = (200, body)
        self.store(self.query_key(query), result, ROUTES[SEQUENCE_PATH])
        return result

    @staticmethod
    def query_key(query):
        return "&".join(f"{key}={query.get(key, '')}" for key in ("category", "number", "evaNumber", "date", "time"))

    @staticmethod
    def describe(query):
        return (f"{query.get('category', '?')} {query.get('number', '?')} at {query.get('evaNumber', '?')}, "
                f"{query.get('time', '?')}")


def ris_proxy(fetch, secret, **options):
    """The proxy for RIS::Journeys: the same tokens and rate, its own cache and pauses."""
    return Proxy(fetch=fetch, secret=secret, prefix=RIS_PREFIX, upstream_base=RIS_UPSTREAM, ttl_for=ris_route_ttl,
                 block_statuses=frozenset(RIS_BLOCK_STATUSES), name="RIS", **options)


def make_app(proxy, ris=None, regio=None):
    """`proxy` (bahn.de) answers everything but RIS_PREFIX, which goes to `ris` (404 without one), and coach
    sequences, which `regio` answers first when there is one."""
    async def handle(request):
        if request.path.startswith(RIS_PREFIX):
            return await ris.handle(request) if ris else json_response(404, {"error": "not_found"})
        if regio and request.path == proxy.prefix + SEQUENCE_PATH:
            return await regio.handle(request)
        return await proxy.handle(request)

    app = web.Application(client_max_size=4096)
    app.router.add_route("*", "/{tail:.*}", handle)
    return app


def main():
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    # aiohttp's access log would record client addresses; the proxy keeps none.
    logging.getLogger("aiohttp.access").setLevel(logging.WARNING)
    secret = os.environ.get("TOKEN_SECRET", "")
    allow_unattested = os.environ.get("ALLOW_UNATTESTED") == "true"
    if not secret and not allow_unattested:
        raise SystemExit("TOKEN_SECRET is missing (the same value as in the Cloudflare Workers).")
    rate_limit = int(os.environ.get("RATE_LIMIT", "120"))
    proxy = Proxy(
        fetch=BrowserFetch(os.environ.get("IMPERSONATE", "safari")),
        secret=secret,
        allow_unattested=allow_unattested,
        first_pause=float(os.environ.get("FIRST_PAUSE", "60")),
        block_pause=float(os.environ.get("BLOCK_PAUSE", "600")),
        max_parallel=int(os.environ.get("MAX_PARALLEL", "4")),
        min_interval=float(os.environ.get("MIN_INTERVAL", "0.25")),
        rate_limit=rate_limit,
    )
    client_id, api_key = os.environ.get("DB_CLIENT_ID", ""), os.environ.get("DB_API_KEY", "")
    ris = ris_proxy(RISFetch(client_id, api_key), secret, allow_unattested=allow_unattested,
                    rate_limit=rate_limit) if client_id and api_key else None
    if ris is None:
        log.info("DB_CLIENT_ID/DB_API_KEY not set: RIS::Journeys answers 404")
    regio = None if os.environ.get("REGIO") == "false" else RegioSequences(
        fetch=RegioFetch(), proxy=proxy, log_path=os.environ.get("REGIO_LOG", "logs/regio.log"))
    web.run_app(make_app(proxy, ris, regio), port=int(os.environ.get("PORT", "8080")), access_log=None)


if __name__ == "__main__":
    main()
