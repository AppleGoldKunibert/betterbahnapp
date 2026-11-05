# bahn.de proxy with a browser fingerprint (#342)

Since October 2026 bahn.de's bot protection (Akamai) refuses every request whose TLS/HTTP2 handshake isn't a
browser's (`403`/`452 OPS_BLOCKED`), whatever its address, User-Agent or cookies. Cloudflare Workers can't
change theirs, so `betterbahn2` is refused. This small server asks bahn.de with
[curl_cffi](https://github.com/lexiforest/curl_cffi), which makes the handshake of a real browser (Safari by
default). Measured on 2026-10-15 from the same Mac: `curl` 403, `curl_cffi` with `safari`, `safari_ios`,
`firefox`, `chrome` and `edge` 200.

bahn.de tolerates this as long as the traffic stays small, as bahn.expert has done it for years. The server keeps
it small:
- **Cache:** answers are cached (30 s for live data, a day for stations) and identical requests share one call.
- **Rate limit:** at most `RATE_LIMIT` requests a minute per app install.
- **One at a time:** at most `MAX_PARALLEL` requests go to bahn.de at once. A burst of 17 parallel requests got the
  server refused (403) on 2026-10-15, while single requests from the same address went through.
- **Spread out:** requests to bahn.de start at least `MIN_INTERVAL` seconds apart. Ten departure boards within a second
  got the server refused (429) on 2026-10-20, although no more than four ran at once.
- **Like bahn.de's page:** a new session first loads the search page (which sets bahn.de's cookies), then asks the API
  with the headers of the page's background requests. Sessions are renewed every hour. Measured 2026-10-16 from a home
  connection: Safari this way 200 for departures and Wagenreihung, from the Oracle VM 403 (a data center address).
- **`Accept-Encoding: gzip, br`**, as DB's RIS API team asks: with the browser's `gzip, deflate, br` bahn.de held each
  answer back for 1–3 s (2026-10-16: the same coach sequence in 3.3 s, with `gzip, br` in 0.23 s).
- **Pause:** after bahn.de refused a request, the server starts a new session (fresh cookies) and nothing goes
  there for `FIRST_PAUSE` seconds; each refusal soon after the last pause doubles it, up to `BLOCK_PAUSE`. Requests
  already running finish on the old session: closing it at once cut them off (curl reported status 0, logged as
  `bahn.de 0 …`, which Tailscale Funnel turned into a 502 that paused the app).

It takes bahn.de's `/web/api/…` paths (GET only, the list in `proxy.py`) and the App Attest tokens of the
`betterbahn2` Worker (`X-BetterBahn-Token`, signed with `TOKEN_SECRET`). It is the app's only way to bahn.de
(`BahnDeProxy` in BetterBahnKit): while it is down, paused or refused, the app shows "Aktuelle Wagenreihung nicht
verfügbar". The server keeps no logs of who asked.
The `betterbahn` Worker also asks it for the live times of shared arrivals when IRIS doesn't have the train
("Ankunft teilen", `Cloudflare/arrival.mjs`: `fahrt` only, cached 30 s per train), with a token of its own (key `arrival-pages`, one rate limit for all of them).

**Tz log (#502):** `tzlog.py` keeps which trainset (Tz) ran which ICE/IC on which day, for a year, in a SQLite file
(`TZ_DB`), and serves it to the app: `GET /tz/list` (every Tz with its latest day's trains) and `GET /tz/history?tz=8043`
(same token and rate limit as `/web/api/`), and `GET /tz/turnaround?category=ICE&number=592&day=2026-11-03`: the trains the
trainset of that train ran as just before and runs as just after it ("Wendet aus / zu"). The turnaround answers from the log and first
refreshes that trainset's journeys at the WiFi host (3 requests: the day and the days around it) when nobody looked at them for 30 minutes,
so the host is only asked while someone looks at a trip, once per trainset and half hour however many look. It runs on one source, the RIS::Transports API behind DB Regio's WiFi landing
page (`RisClient`): every `TZ_VEHICLE_EVERY` seconds one request per known Tz asks the journeys of one of its coaches
(`/api/transports/vehicles/<UIC>/journeys?date=`), the first time also the last 6 days, and from noon on tomorrow's early trains too. No login: like the page itself it loads
the landing page and sends its CSRF cookie and token back. It is not a documented API, so DB can change or close it; the log
then stops growing from there. About 400 requests a day, `TZ_RIS_INTERVAL` apart, plus ~2400 once for the first week.
Each vehicle round also writes a row to the `rounds` table of `tz.db` (requests, answers per HTTP status, why it stopped), as a panel's console is gone after minutes: `sqlite3 tz.db 'select * from rounds order by id desc limit 5'`.

- **The Tz list is a file:** `tz_seed.json` has every known Tz with the UIC number of one coach and is loaded at start.
  `make_tz_seed.py` makes and extends it: it reads the boards of 15 stations once (about 700 requests to bahn.de through
  this server), and keeps only Tz whose coach the WiFi host confirms. Run it on a few days until the list stops growing,
  e.g. `python3 Server/bahnde-proxy/make_tz_seed.py` from a cloud session (the network secret adds the token).
- **New Tz:** after each vehicle round the server reads the ICE/IC boards of 6 big stations (`HUBS`) for the rest of the day
  and asks the Wagenreihung only of trains the vehicle round did not explain (those have a Tz the list lacks). With
  nothing new that is about 100 board requests a day to bahn.de, `TZ_SCAN_INTERVAL` apart, through the proxy's cache, turn-taking
  and pause. `TZ_BOARDS=false` never asks bahn.de.

Only ICE and ICD (IC 2) groups with a Tz are kept, no loco-hauled IC 1. It records nothing about who asks. On a panel
server the file lives next to the code and survives restarts; with Docker it is the `tzlog` volume. `TZ_SCAN=false`
stops the scan (the log is still served), `TZ_RIS=false` the WiFi host.

| Variable | Default | |
| --- | --- | --- |
| `TOKEN_SECRET` | — | Required. The same value as in `betterbahn2`, `betterbahn`, `betterbahn-pass`. |
| `PORT` | `8080` | |
| `IMPERSONATE` | `safari` | curl_cffi browser target. If bahn.de starts refusing it, try `safari_ios`, `firefox` or `chrome`. |
| `FIRST_PAUSE` | `60` | Seconds without bahn.de requests after a 403/429/452. |
| `BLOCK_PAUSE` | `600` | The longest pause, reached when refusals keep coming. |
| `MAX_PARALLEL` | `4` | Requests going to bahn.de at the same time. |
| `MIN_INTERVAL` | `0.25` | Seconds between the starts of two requests to bahn.de. |
| `RATE_LIMIT` | `120` | Requests per minute per app install. |
| `TZ_DB` | `tz.db` next to `proxy.py` (`/data/tz.db` in Docker) | The Tz log's SQLite file. |
| `TZ_SCAN` | `true` | `false` turns the scan off. |
| `TZ_SCAN_INTERVAL` | `3` | Seconds between two requests of the scan. |
| `TZ_SEED` | `tz_seed.json` next to `proxy.py` | The known Tz (see above). |
| `TZ_BOARDS` | `true` | `false` never reads bahn.de's boards. |
| `TZ_SCAN_EVERY` | `43200` | Seconds between two board scans (each reads up to midnight at most). |
| `TZ_RIS` | `true` | `false` turns the WiFi host (vehicle lookups) off. |
| `TZ_RIS_INTERVAL` | `1` | Seconds between two requests to the WiFi host. |
| `TZ_VEHICLE_EVERY` | `43200` | Seconds between two vehicle rounds. |
| `ALLOW_UNATTESTED` | — | `true` lets requests without a token through. Only for a quick test, never in production. |

## Run it

It is a plain Docker image (`Dockerfile`) and needs HTTPS in front of it. Once it runs, put its address into
`BahnDeProxy.baseURL` (BetterBahnKit) and ship an app build. Check it with `curl https://<address>/health`.

**Oracle Cloud "Always Free"** (2026-10-15, given up the next day): bahn.de refused its addresses, reserved and
ephemeral alike, with `OPS_BLOCKED` for departures and coach sequences (only `orte` went through), even after a
night without requests. A `VM.Standard.A1.Flex` (1 OCPU, 6 GB, Ubuntu 24.04, region Frankfurt) with Docker and
Caddy in front. Setting it up:
1. Create the instance (any availability domain with A1 capacity, else `VM.Standard.E2.1.Micro`), a new VCN with a
   public subnet, then "Connect public subnet to internet" and a reserved public IP on the VNIC (Networking → IP management → Reserved public IPs; it survives recreating the VM,
   an ephemeral one doesn't). The app has the address built in, so a new IP needs an app update.
2. In the instance's network security group, allow TCP 80 and 443 from `0.0.0.0/0`.
3. On the VM: install Docker (`curl -fsSL https://get.docker.com | sudo sh`), clone the repo, put `TOKEN_SECRET=…` into
   `Server/bahnde-proxy/.env`, `docker compose up -d --build`.
4. `sudo iptables -I INPUT -p tcp --dport 80 -j ACCEPT`, the same for 443, `sudo netfilter-persistent save`,
   `sudo apt-get install -y caddy`, and `/etc/caddy/Caddyfile`: `<ip-with-dashes>.sslip.io { reverse_proxy localhost:8080 }`.
5. Updates: `git pull && docker compose up -d --build` in this folder.

Oracle may reclaim idle Always Free VMs (CPU, network and memory below 20 % over 7 days); a Pay As You Go account
reportedly isn't affected, and Always Free resources stay free there.

**Free container hosting** (e.g. Koyeb, Render): create a web service from this folder (`Server/bahnde-proxy`,
Dockerfile), set `TOKEN_SECRET` as a secret and pick a region in Germany or nearby (Frankfurt). The host gives you
an HTTPS address. Free services that sleep when idle make the first request after a pause slow; the app then shows
no live data for two minutes. Their addresses are shared cloud ranges, which Akamai may treat more strictly than a
home connection.

**Where it runs now: a game-server panel** (Pterodactyl, a "Python" server without Docker or root), at
`https://bahnde-proxy.tail6eed6b.ts.net` (`BahnDeProxy.baseURL`). The small host's
address got 200 from bahn.de where Oracle's were refused (2026-10-16). `panel_start.py` brings HTTPS with
Tailscale Funnel and starts the proxy:
1. Upload only `panel_boot.py` and a `.env` next to it with `TOKEN_SECRET=…` and `BRANCH=<branch>`. On every
   start it downloads the server code of that branch from GitHub, installs the requirements and runs
   `panel_start.py`.
2. Startup: Python 3.12 or 3.13 image if there is a choice, app file `panel_boot.py`, no requirements file.
3. Start it and open the Tailscale links in the console (sign in, enable Funnel). It then prints the
   `https://<name>.<tailnet>.ts.net` address; put it into `BahnDeProxy.baseURL`. Updates: restart the server.

**Home server or VPS:**

```sh
cd Server/bahnde-proxy
echo "TOKEN_SECRET=…" > .env          # not committed (.gitignore)
docker compose up -d --build          # listens on 127.0.0.1:8080
```

HTTPS from outside, for example:
- **Cloudflare Tunnel** (free, no open port): `cloudflared tunnel --url http://localhost:8080` for a quick test,
  or a named tunnel with your own hostname. Only the app's requests come in through Cloudflare; the requests to
  bahn.de leave from the server's own address.
- **Caddy** with a domain pointing at the server: `caddy reverse-proxy --from proxy.example.de --to localhost:8080`.

A quick test without the app (remove `ALLOW_UNATTESTED` afterwards):

```sh
docker run --rm -p 8080:8080 -e ALLOW_UNATTESTED=true $(docker build -q .)
curl "http://localhost:8080/web/api/reiseloesung/orte?suchbegriff=Berlin&typ=ALL&limit=1"
```

## Tests

`python3 -m unittest Server/bahnde-proxy/proxy_test.py Server/bahnde-proxy/tzlog_test.py Server/bahnde-proxy/panel_boot_test.py` (needs `aiohttp`; no network).
