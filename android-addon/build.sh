#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
sdk="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}"
if [[ -z "$sdk" ]]; then
  echo 'Set ANDROID_SDK_ROOT to your Android SDK directory.' >&2
  exit 1
fi
build_tools="$sdk/build-tools/36.0.0"
android_jar="$sdk/platforms/android-36/android.jar"
for tool in javac java jar; do command -v "$tool" >/dev/null || { echo "Missing tool: $tool" >&2; exit 1; }; done
[[ -f "$android_jar" && -x "$build_tools/d8" ]] || { echo 'Install Android SDK platform 36 and build-tools 36.0.0.' >&2; exit 1; }
mkdir -p build/classes build/test build/dex
javac -encoding UTF-8 -source 8 -target 8 -d build/test \
  src/com/turboio/addon/ChatPolicy.java src/com/turboio/addon/NavCore.java \
  src/com/turboio/addon/NavSessionPolicy.java src/com/turboio/addon/NavSimulation.java tests/*.java
for test in ChatPolicyTest NavCoreTest NavSessionPolicyTest NavSimulationTest; do java -cp build/test "$test"; done
javac -encoding UTF-8 -source 8 -target 8 -cp "$android_jar" -d build/classes src/com/turboio/addon/*.java
jar cf build/turboio-addon.jar -C build/classes .
"$build_tools/d8" --lib "$android_jar" --min-api 29 --output build/dex build/turboio-addon.jar
echo 'Built build/dex/classes.dex (original addon only; no API keys).'
