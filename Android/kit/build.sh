#!/bin/bash
# Builds BetterBahnKit for Android with the Swift SDK for Android (macOS, Linux or WSL2; not native Windows).
#   Android/kit/build.sh            # debug, arm64 (phones) and x86_64 (emulator on a Windows/Intel PC)
#   Android/kit/build.sh release    # optimized
#   KIT_ARCHS=x86_64 Android/kit/build.sh   # only the emulator's (build-wsl.sh does that)
# Needs a Swift toolchain and the matching Swift SDK for Android (https://www.swift.org/documentation/articles/swift-sdk-for-android-getting-started.html)
# plus the Android NDK (ANDROID_NDK_HOME). The libraries land in Android/app/src/main/jniLibs/<abi>/.
set -euo pipefail
K=$(cd "$(dirname "$0")" && pwd)
KIT="$K/../../Packages/BetterBahnKit/Sources/BetterBahnKit"
CONFIG=${1:-debug}
API=${ANDROID_API:-28}
swift sdk list | grep -q android || { echo "No Swift SDK for Android installed (swift sdk list)." >&2; exit 1; }

# The Kit's source folders, linked fresh each time so new folders are picked up, plus the Android stand-ins.
rm -rf "$K/Sources/BetterBahnKit" && mkdir -p "$K/Sources/BetterBahnKit"
for d in "$KIT"/*/; do ln -s "$(cd "$d" && pwd)" "$K/Sources/BetterBahnKit/$(basename "$d")"; done
ln -s "$K/Shims" "$K/Sources/BetterBahnKit/AndroidShims"

for arch in ${KIT_ARCHS:-aarch64 x86_64}; do
  case $arch in aarch64) abi=arm64-v8a;; x86_64) abi=x86_64;; esac
  args=(--package-path "$K" -c "$CONFIG" --swift-sdk "$arch-unknown-linux-android$API" --static-swift-stdlib --scratch-path "$K/.build")
  swift build "${args[@]}"
  bin=$(swift build "${args[@]}" --show-bin-path)
  out="$K/../app/src/main/jniLibs/$abi"
  mkdir -p "$out"
  # Without symbols: ~60 instead of ~100 MB (most of what's left is the ICU data Foundation needs).
  "$(find "${ANDROID_NDK_HOME:?}/toolchains/llvm/prebuilt" -name llvm-strip | head -1)" --strip-unneeded \
    -o "$out/libBetterBahnKit.so" "$bin/libBetterBahnKit.so"
  # The Swift runtime is linked in statically; only the NDK's C++ library has to ship next to it.
  cp "$(find "$ANDROID_NDK_HOME/toolchains/llvm/prebuilt" -path "*/$arch-linux-android/libc++_shared.so" | head -1)" "$out/"

  # Android refuses to load a library with a symbol none of its libraries provide, so the app would crash at
  # launch (as it did when OpenSSL was missing). Every strong undefined symbol must come from the system libraries
  # it links (API $API) or the libc++ shipped next to it.
  nm=$(find "$ANDROID_NDK_HOME/toolchains/llvm/prebuilt" -name llvm-nm | head -1)
  sysroot=$(find "$ANDROID_NDK_HOME/toolchains/llvm/prebuilt" -maxdepth 2 -name sysroot | head -1)/usr/lib/$arch-linux-android
  provided=$(for lib in c m dl log z; do "$nm" -D --defined-only "$sysroot/$API/lib$lib.so"; done
             "$nm" -D --defined-only "$out/libc++_shared.so")
  missing=$(comm -23 <("$nm" -D --undefined-only "$out/libBetterBahnKit.so" | awk '$1 == "U" {print $2}' | sed 's/@.*//' | sort -u) \
                     <(awk '{print $NF}' <<< "$provided" | sed 's/@.*//' | sort -u))
  if [ -n "$missing" ]; then
    echo "libBetterBahnKit.so ($abi) needs symbols no library on the phone provides:" >&2
    head -20 <<< "$missing" >&2
    exit 1
  fi
done
# The Kit's JSON data (station names, platforms, seat maps …), shipped as app assets.
rm -rf "$K/../app/src/main/assets/BetterBahnKit" && mkdir -p "$K/../app/src/main/assets"
cp -r "$bin/BetterBahnKitAndroid_BetterBahnKit.bundle" "$K/../app/src/main/assets/BetterBahnKit"
echo "Built BetterBahnKit ($CONFIG) for ${KIT_ARCHS:-aarch64 x86_64}."
