#!/bin/bash
set -e

# Download and unzip iOS framework
IOS_URL="https://github.com/sk3llo/ffmpeg_kit_flutter/releases/download/8.0.0-full-gpl/ffmpeg-kit-ios-full-gpl-8.0.0.zip"
mkdir -p Frameworks
curl -L $IOS_URL -o frameworks.zip
unzip -o frameworks.zip -d Frameworks
rm frameworks.zip

# Strip macOS metadata leaked by zip
rm -rf Frameworks/__MACOSX
find Frameworks -name "._*" -delete

FRAMEWORKS="ffmpegkit libavcodec libavdevice libavfilter libavformat libavutil libswresample libswscale"

DEVICE_DIR="Frameworks/_device"
SIM_DIR="Frameworks/_simulator"
mkdir -p "$DEVICE_DIR" "$SIM_DIR"

# The upstream fat binary contains: arm64 + arm64e (iOS-device) and x86_64 (iOS-simulator).
# To support Apple Silicon simulators we synthesize an arm64 simulator slice by
# re-tagging the device arm64 slice with the iOS-Simulator build version (platform 7).
# This trick is safe for purely userspace libraries like ffmpeg-kit.

for FW in $FRAMEWORKS; do
  SRC="Frameworks/${FW}.framework"
  if [ ! -d "$SRC" ]; then
    echo "Skipping ${FW}: source framework not found"
    continue
  fi

  # Strip bitcode from the fat binary
  xcrun bitcode_strip -r "$SRC/$FW" -o "$SRC/$FW"

  ARCHS_IN_FAT=$(lipo -archs "$SRC/$FW")

  TMP_DIR=$(mktemp -d)

  # --- Device framework: arm64 + arm64e (iOS) ------------------------------
  rm -rf "$DEVICE_DIR/${FW}.framework"
  cp -R "$SRC" "$DEVICE_DIR/${FW}.framework"
  DEV_ARCH_ARGS=""
  for A in arm64 arm64e; do
    if echo "$ARCHS_IN_FAT" | grep -qw "$A"; then
      DEV_ARCH_ARGS="$DEV_ARCH_ARGS -extract $A"
    fi
  done
  if [ -n "$DEV_ARCH_ARGS" ]; then
    lipo "$SRC/$FW" $DEV_ARCH_ARGS -output "$DEVICE_DIR/${FW}.framework/$FW"
  fi

  # --- Simulator framework: x86_64 (real) + arm64 (retagged from device) ----
  rm -rf "$SIM_DIR/${FW}.framework"
  cp -R "$SRC" "$SIM_DIR/${FW}.framework"

  SIM_SLICES=""

  if echo "$ARCHS_IN_FAT" | grep -qw "x86_64"; then
    lipo "$SRC/$FW" -extract x86_64 -output "$TMP_DIR/${FW}.x86_64"
    SIM_SLICES="$SIM_SLICES $TMP_DIR/${FW}.x86_64"
  fi

  if echo "$ARCHS_IN_FAT" | grep -qw "arm64"; then
    lipo "$SRC/$FW" -thin arm64 -output "$TMP_DIR/${FW}.arm64.dev"
    # Retag platform from iOS (2) to iOS Simulator (7).
    xcrun vtool -arch arm64 \
      -set-build-version 7 14.0 14.0 \
      -replace \
      -output "$TMP_DIR/${FW}.arm64.sim" \
      "$TMP_DIR/${FW}.arm64.dev"
    SIM_SLICES="$SIM_SLICES $TMP_DIR/${FW}.arm64.sim"
  fi

  if [ -n "$SIM_SLICES" ]; then
    lipo -create $SIM_SLICES -output "$SIM_DIR/${FW}.framework/$FW"
  fi

  rm -rf "$TMP_DIR"

  # --- Assemble the xcframework --------------------------------------------
  rm -rf "Frameworks/${FW}.xcframework"
  xcodebuild -create-xcframework \
    -framework "$DEVICE_DIR/${FW}.framework" \
    -framework "$SIM_DIR/${FW}.framework" \
    -output "Frameworks/${FW}.xcframework"

  rm -rf "$SRC"
done

rm -rf "$DEVICE_DIR" "$SIM_DIR"
