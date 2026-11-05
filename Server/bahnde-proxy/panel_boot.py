"""The only file to upload to a game-server panel: fetches the proxy from GitHub on every start, then runs it.

Put it next to a .env file and make it the panel's app file (no requirements file needed). .env:
    TOKEN_SECRET=…          same value as in the Cloudflare Workers
    BRANCH=indevelopment    the branch to take the server code from
    REPO=AppleGoldKunibert/betterbahnapp   (optional)
On each start it downloads proxy.py, panel_start.py and requirements.txt of Server/bahnde-proxy from that
branch, plus tzlog.py and tz_seed.json when the branch has them, installs the requirements when they changed and
hands over to panel_start.py (HTTPS through Tailscale Funnel, see there). If GitHub can't be reached or a needed file
is missing on the branch, it starts the code it downloaded last time.
"""

import hashlib
import os
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
FILES = ("proxy.py", "panel_start.py", "requirements.txt")
# Only on branches with the Tz log (#502): a branch without them still starts its own code.
OPTIONAL_FILES = ("tzlog.py", "tz_seed.json")


def load_env():
    env = HERE / ".env"
    if not env.exists():
        raise SystemExit(f"{env} is missing (TOKEN_SECRET=… and BRANCH=…).")
    for line in env.read_text().splitlines():
        key, sep, value = line.strip().partition("=")
        if sep and key and not key.startswith("#"):
            os.environ.setdefault(key.strip(), value.strip().strip("\"'"))


def download(url):
    return urllib.request.urlopen(url, timeout=20).read()


def update(fetch=download):
    repo = os.environ.get("REPO", "AppleGoldKunibert/betterbahnapp")
    branch = os.environ.get("BRANCH", "indevelopment")
    base = f"https://raw.githubusercontent.com/{repo}/{branch}/Server/bahnde-proxy/"
    print(f"Updating from {repo}@{branch} …", flush=True)
    downloaded = {}
    try:
        for name in FILES + OPTIONAL_FILES:
            try:
                downloaded[name] = fetch(base + name)
            except urllib.error.HTTPError as error:
                if error.code == 404 and name in OPTIONAL_FILES:
                    continue
                if error.code == 404:
                    raise OSError(f"{name} isn't on {repo}@{branch}") from error
                raise
    except OSError as error:
        if all((HERE / name).exists() for name in FILES):
            print(f"Can't update ({error}), starting the last downloaded version.", flush=True)
            return
        raise SystemExit(f"Can't download the server code from {base}: {error}")
    for name, content in downloaded.items():
        (HERE / name).write_bytes(content)


def install():
    requirements = HERE / "requirements.txt"
    stamp = HERE / ".requirements.sha256"
    digest = hashlib.sha256(requirements.read_bytes()).hexdigest()
    if stamp.exists() and stamp.read_text() == digest:
        return
    print("Installing requirements …", flush=True)
    user = [] if sys.prefix != sys.base_prefix else ["--user"]  # a venv has no user site
    subprocess.run([sys.executable, "-m", "pip", "install", *user, "--quiet", "-r", str(requirements)], check=True)
    stamp.write_text(digest)


def main():
    load_env()
    update()
    install()
    os.execv(sys.executable, [sys.executable, str(HERE / "panel_start.py")])


if __name__ == "__main__":
    main()
