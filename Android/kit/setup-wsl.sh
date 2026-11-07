#!/bin/bash
# Sets up WSL2 (Ubuntu 22.04 or 24.04) once so Android Studio on Windows can build BetterBahnKit for Android: the
# Swift toolchain, the Swift SDK for Android, the Android NDK and rsync. Run it inside WSL, from the repository:
#   sed 's/\r$//' Android/kit/setup-wsl.sh | bash
# Asks for your WSL password once (apt). Takes ~5 GB in your WSL home and a few minutes. Afterwards every "Run" in
# Android Studio builds the Kit through WSL when it changed (Android/app/build.gradle.kts, kit/build-wsl.sh).
set -euo pipefail
V=6.4.1                    # Swift, as android-build.yml
SDK_CHECKSUM=a356b79f8f1daa6ae3a66f4c556966ca20c0208b3659805cf30a83a0a31d6772
NDK=r27d                   # 27.3.13750724
T="$HOME/.local/share/betterbahn-toolchain"
ENV_FILE="$HOME/.betterbahn-android.env"

. /etc/os-release
case "${VERSION_ID:-}" in
  24.04) platform=ubuntu2404; gcc=13 ;;
  22.04) platform=ubuntu2204; gcc=11 ;;
  *) echo "WSL needs Ubuntu 22.04 or 24.04 (this is ${PRETTY_NAME:-unknown})." >&2; exit 1 ;;
esac
SUDO=$([ "$(id -u)" = 0 ] && echo "" || echo sudo)

echo "Installing packages (apt)…"
$SUDO apt-get update -q > /dev/null
$SUDO apt-get install -y -q binutils curl git gnupg2 libc6-dev libcurl4-openssl-dev libedit2 "libgcc-$gcc-dev" \
  libncurses-dev libpython3-dev libsqlite3-0 "libstdc++-$gcc-dev" libxml2-dev libz3-dev pkg-config rsync tzdata unzip \
  zlib1g-dev > /dev/null

mkdir -p "$T"
if [ ! -x "$T/swift/usr/bin/swift" ]; then
  echo "Downloading Swift $V…"
  mkdir -p "$T/swift"
  curl -sSfL "https://download.swift.org/swift-$V-release/$platform/swift-$V-RELEASE/swift-$V-RELEASE-ubuntu$VERSION_ID.tar.gz" \
    -o "$T/swift.tar.gz"
  tar -xzf "$T/swift.tar.gz" -C "$T/swift" --strip-components=1 && rm "$T/swift.tar.gz"
fi
export PATH="$T/swift/usr/bin:$PATH"

if [ ! -d "$T/android-ndk-$NDK" ]; then
  echo "Downloading the Android NDK $NDK…"
  curl -sSfL "https://dl.google.com/android/repository/android-ndk-$NDK-linux.zip" -o "$T/ndk.zip"
  unzip -q "$T/ndk.zip" -d "$T" && rm "$T/ndk.zip"
fi
export ANDROID_NDK_HOME="$T/android-ndk-$NDK"

if ! swift sdk list 2>/dev/null | grep -q "swift-$V-RELEASE_android"; then
  echo "Installing the Swift SDK for Android…"
  swift sdk install "https://download.swift.org/swift-$V-release/android-sdk/swift-$V-RELEASE/swift-$V-RELEASE_android.artifactbundle.tar.gz" \
    --checksum "$SDK_CHECKSUM"
fi
home=$(getent passwd "$(id -u)" | cut -d: -f6)
setup=$({ find "$home/.swiftpm" "$home/.config/swiftpm" -name setup-android-sdk.sh -path "*swift-$V-RELEASE_android*" 2>/dev/null || true; } | head -1)
[ -n "$setup" ] || { echo "The Swift SDK for Android's setup-android-sdk.sh wasn't found." >&2; exit 1; }
"$setup" > /dev/null

# Read by build-wsl.sh, which Gradle starts without a login shell.
printf 'export PATH="%s:$PATH"\nexport ANDROID_NDK_HOME="%s"\n' "$T/swift/usr/bin" "$ANDROID_NDK_HOME" > "$ENV_FILE"
echo "Done. Android Studio now builds the Kit through WSL on every Run."
