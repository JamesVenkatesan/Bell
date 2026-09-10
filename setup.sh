#!/usr/bin/env bash
# Generates Bell.xcodeproj and opens it. Run from the Bell/ directory.
set -euo pipefail

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "XcodeGen isn't installed. Installing via Homebrew..."
  if ! command -v brew >/dev/null 2>&1; then
    echo "Homebrew isn't installed either. Install it from https://brew.sh then rerun."
    exit 1
  fi
  brew install xcodegen
fi

if [ ! -f Resources/Events.xml ]; then
  echo "Resources/Events.xml is missing — that's your schedule. Unzip your"
  echo ".timetable export and copy Events.xml into Resources/ first."
  exit 1
fi

echo "Generating project..."
xcodegen generate

echo
echo "Done. Next:"
echo "  1. open Bell.xcodeproj"
echo "  2. Select the Bell target, Signing & Capabilities, pick your team"
echo "  3. Do the same for the BellWidget target"
echo "  4. Change the bundle IDs off com.yourteam if signing complains"
echo "  5. Run on the simulator before your device"
echo

open Bell.xcodeproj 2>/dev/null || true
