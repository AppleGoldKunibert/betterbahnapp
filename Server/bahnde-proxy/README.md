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
- **Pause:** after bahn.de refused a request, the server starts a new session (fresh cookies) and nothing goes
  there for `FIRST_PAUSE` seconds; each refusal soon after the last pause doubles it, up to `BLOCK_PAUSE`.

It mirrors the Worker: the same `/web/api/…` paths (GET only, the list in `proxy.py`) and the same App Attest
tokens (`X-BetterBahn-Token`, signed with `TOKEN_SECRET`). The app asks it first (`BahnDeProxy` in
BetterBahnKit). While it is down, paused or refused, the app uses `betterbahn2` and the phone's hidden browser
as before. The server keeps no logs of who asked.

| Variable | Default | |
| --- | --- | --- |
| `TOKEN_SECRET` | — | Required. The same value as in `betterbahn2`, `betterbahn`, `betterbahn-pass`. |
| `PORT` | `8080` | |
| `IMPERSONATE` | `safari` | curl_cffi browser target. If bahn.de starts refusing it, try `safari_ios`, `firefox` or `chrome`. |
| `FIRST_PAUSE` | `60` | Seconds without bahn.de requests after a 403/429/452. |
| `BLOCK_PAUSE` | `600` | The longest pause, reached when refusals keep coming. |
| `MAX_PARALLEL` | `4` | Requests going to bahn.de at the same time. |
| `RATE_LIMIT` | `120` | Requests per minute per app install. |
| `ALLOW_UNATTESTED` | — | `true` lets requests without a token through. Only for a quick test, never in production. |

## Run it

It is a plain Docker image (`Dockerfile`) and needs HTTPS in front of it. Once it runs, put its address into
`BahnDeProxy.baseURL` (BetterBahnKit) and ship an app build. Check it with `curl https://<address>/health`.

**Where it runs now: Oracle Cloud "Always Free"** (since 2026-10-15). A `VM.Standard.A1.Flex` (1 OCPU, 6 GB,
Ubuntu 24.04, region Frankfurt) with Docker and Caddy in front, at `https://92-5-144-111.sslip.io` (`BahnDeProxy.baseURL`).
bahn.de answered 200 from its address. Setting it up again:
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
an HTTPS address. Free services that sleep when idle make the first request after a pause slow; the app then uses
the Worker for two minutes. Their addresses are shared cloud ranges, which Akamai may treat more strictly than a
home connection.

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

`python3 -m unittest Server/bahnde-proxy/proxy_test.py` (needs `aiohttp`; no network).
