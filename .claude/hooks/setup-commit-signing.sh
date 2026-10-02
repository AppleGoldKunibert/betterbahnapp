#!/bin/bash
# Cloud sessions: sign commits as goldkunibert with the key from the GIT_SIGNING_KEY
# environment variable (base64 of an SSH private key). No-op when the variable is unset.
[ -n "$GIT_SIGNING_KEY" ] || exit 0

if ! command -v ssh-keygen >/dev/null; then
  (apt-get update -qq && apt-get install -y -qq openssh-client) >/dev/null 2>&1 || exit 0
fi

key="$HOME/.ssh/betterbahn_cloud_signing"
mkdir -p "$HOME/.ssh"
printf '%s' "$GIT_SIGNING_KEY" | base64 -d > "$key" || exit 0
chmod 600 "$key"
ssh-keygen -y -f "$key" > "$key.pub" || exit 0

git config --global user.name goldkunibert
git config --global user.email 212144512+goldkunibert@users.noreply.github.com
git config --global gpg.format ssh
git config --global gpg.ssh.program ssh-keygen
git config --global user.signingkey "$key"
git config --global commit.gpgsign true
