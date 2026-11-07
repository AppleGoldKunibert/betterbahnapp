#!/bin/bash
# Builds BetterBahnKit for Android (the emulator's x86_64) inside WSL2 for Android Studio on Windows
# (Android/app/build.gradle.kts runs it before every build whose Kit sources changed). Runs from the repository's root on the Windows drive. The sources
# are mirrored into WSL's own file system first: building on /mnt/c is slow and its symlinks are unreliable. The
# libraries and the Kit's data are copied back to where build.sh puts them on other systems.
# Setup once: Android/kit/setup-wsl.sh.
set -euo pipefail
ENV_FILE="$HOME/.betterbahn-android.env"
[ -f "$ENV_FILE" ] || {
  echo "WSL isn't set up for the Android Kit yet. In WSL, from the repository, run once:" >&2
  echo "  sed 's/\\r\$//' Android/kit/setup-wsl.sh | bash" >&2
  exit 1
}
. "$ENV_FILE"
R=$(pwd)
[ -d "$R/Android/kit" ] && [ -d "$R/Packages/BetterBahnKit/Sources" ] || { echo "Run from the repository's root." >&2; exit 1; }
M="$HOME/.cache/betterbahn-kit"
mkdir -p "$M/Android/kit" "$M/Packages/BetterBahnKit/Sources"
rsync -a --delete --exclude .build --exclude Sources --exclude .linux-test --exclude .linux-bridge \
  "$R/Android/kit/" "$M/Android/kit/"
rsync -a --delete "$R/Packages/BetterBahnKit/Sources/" "$M/Packages/BetterBahnKit/Sources/"
# A Windows checkout may have turned the scripts' line endings into CRLF.
sed -i 's/\r$//' "$M/Android/kit/"*.sh

# Only for the emulator (x86_64), which halves the build; phones' arm64 comes from CI. KIT_ARCHS="aarch64 x86_64"
# builds both.
rm -rf "$M/Android/app/src/main/jniLibs"
KIT_ARCHS=${KIT_ARCHS:-x86_64} bash "$M/Android/kit/build.sh" "$@"

main="$R/Android/app/src/main"
rm -rf "$main/jniLibs" "$main/assets/BetterBahnKit"
mkdir -p "$main/assets"
cp -r "$M/Android/app/src/main/jniLibs" "$main/jniLibs"
cp -r "$M/Android/app/src/main/assets/BetterBahnKit" "$main/assets/BetterBahnKit"
