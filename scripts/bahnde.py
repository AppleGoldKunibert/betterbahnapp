#!/usr/bin/env python3
"""Asks bahn.de through our server (Server/bahnde-proxy) from a cloud session, for debugging.

    python3 scripts/bahnde.py 'reiseloesung/abfahrten?datum=2026-10-21&zeit=15:00:00&ortExtId=8011160&ortId=A%3D1%40L%3D8011160%40&mitVias=false'

Signs a 10-minute app token with TOKEN_SECRET from the environment (never printed) and prints the JSON answer.
"""
import base64
import hashlib
import hmac
import json
import os
import sys
import time
import urllib.request

BASE = "https://bahnde-proxy.tail6eed6b.ts.net/web/api/"


def b64(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def token(secret):
    payload = b64(json.dumps({"t": "a", "kid": "claude-debug", "exp": int(time.time()) + 600}).encode())
    return payload + "." + b64(hmac.new(secret.encode(), payload.encode(), hashlib.sha256).digest())


def main():
    secret = os.environ.get("TOKEN_SECRET")
    if not secret or len(sys.argv) != 2:
        sys.exit("usage: TOKEN_SECRET=… scripts/bahnde.py '<path below /web/api/ with query>'")
    request = urllib.request.Request(BASE + sys.argv[1].lstrip("/"), headers={"X-BetterBahn-Token": token(secret)})
    with urllib.request.urlopen(request, timeout=30) as response:
        print(json.dumps(json.load(response), ensure_ascii=False, indent=1))


if __name__ == "__main__":
    main()
