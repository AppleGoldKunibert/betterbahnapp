"""Starts the proxy on a game-server panel (Pterodactyl and the like): no Docker, no root, only Python.

Such hosts give the server an IP and a port but no HTTPS, which the app needs. This script brings HTTPS
with Tailscale Funnel (a fixed https://<name>.<tailnet>.ts.net address, no open port needed): it downloads
Tailscale into ./tailscale, runs it without root (userspace networking), lets Funnel pass HTTPS on to the
proxy and then starts proxy.py.

Settings come from the environment or from .env next to this file (TOKEN_SECRET=…, one per line). On the
first start the console shows a Tailscale login link, and if Funnel isn't enabled on the tailnet yet, a
second link to enable it; open them, the start goes on by itself. TS_AUTHKEY (a Tailscale auth key) skips
the login.
"""

import json
import os
import platform
import subprocess
import sys
import tarfile
import time
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
TS_DIR = HERE / "tailscale"
TS_VERSION = "1.104.1"
ARCHS = {"x86_64": "amd64", "amd64": "amd64", "aarch64": "arm64", "arm64": "arm64"}


def load_env():
    env = HERE / ".env"
    if not env.exists():
        return
    for line in env.read_text().splitlines():
        key, sep, value = line.strip().partition("=")
        if sep and key and not key.startswith("#"):
            os.environ.setdefault(key.strip(), value.strip().strip("\"'"))


def install_tailscale():
    if (TS_DIR / "tailscaled").exists():
        return
    arch = ARCHS.get(platform.machine().lower())
    if not arch:
        raise SystemExit(f"No Tailscale build for {platform.machine()}.")
    name = f"tailscale_{TS_VERSION}_{arch}"
    print(f"Downloading {name} …", flush=True)
    TS_DIR.mkdir(exist_ok=True)
    archive = TS_DIR / f"{name}.tgz"
    urllib.request.urlretrieve(f"https://pkgs.tailscale.com/stable/{name}.tgz", archive)
    with tarfile.open(archive) as tar:
        for tool in ("tailscale", "tailscaled"):
            member = tar.getmember(f"{name}/{tool}")
            member.name = tool
            tar.extract(member, TS_DIR, filter="data")
            (TS_DIR / tool).chmod(0o755)
    archive.unlink()


def tailscale(*args, **kwargs):
    return subprocess.run([TS_DIR / "tailscale", f"--socket={TS_DIR / 'tailscaled.sock'}", *args], **kwargs)


def start_tailscale(port):
    (TS_DIR / "tailscaled.sock").unlink(missing_ok=True)  # left over from the last run
    log = open(TS_DIR / "tailscaled.log", "ab")
    subprocess.Popen(
        [TS_DIR / "tailscaled", "--tun=userspace-networking", f"--statedir={TS_DIR / 'state'}",
         f"--socket={TS_DIR / 'tailscaled.sock'}"],
        stdout=log, stderr=log,
    )
    for _ in range(100):
        if (TS_DIR / "tailscaled.sock").exists():
            break
        time.sleep(0.1)
    up = ["up", "--hostname", os.environ.get("TS_HOSTNAME", "bahnde-proxy")]
    if os.environ.get("TS_AUTHKEY"):
        up.append(f"--auth-key={os.environ['TS_AUTHKEY']}")
    print("Tailscale: signing in (open the link below if one appears) …", flush=True)
    tailscale(*up, check=True)
    tailscale("funnel", "--bg", str(port), check=True)
    status = json.loads(tailscale("status", "--json", capture_output=True, text=True).stdout)
    host = status["Self"]["DNSName"].rstrip(".")
    print(f"Proxy address for the app: https://{host}  (check: https://{host}/health)", flush=True)


def main():
    load_env()
    port = os.environ.setdefault("PORT", "8080")
    install_tailscale()
    start_tailscale(port)
    os.execv(sys.executable, [sys.executable, str(HERE / "proxy.py")])


if __name__ == "__main__":
    main()
