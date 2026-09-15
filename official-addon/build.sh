#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
mode=${1:-embedded}
bundle=${2:-com.rayneo.venus.pub}
if [[ ! "$bundle" =~ ^[A-Za-z0-9][A-Za-z0-9.-]+\.[A-Za-z0-9.-]+$ ]]; then
  echo 'Invalid explicit target Bundle ID' >&2; exit 2
fi
case "$mode" in
  jailbreak) output=build/TurboIOPrivateAddon.dylib; install_name=/var/jb/usr/lib/TweakInject/TurboIOPrivateAddon.dylib ;;
  embedded) output=build/embedded/TurboIOPrivateAddon.dylib; install_name=@rpath/TurboIOPrivateAddon.dylib; mkdir -p build/embedded ;;
  *) echo 'Usage: build.sh [jailbreak|embedded] [target.bundle.id]' >&2; exit 2 ;;
esac
nav_options=()
if [[ ${TIO_AMAP_ENABLED:-0} == 1 ]]; then
  [[ "$mode" == embedded ]] || { echo 'Navigation requires embedded mode' >&2; exit 2; }
  nav_root="${TIO_AMAP_SDK_ROOT:-$PWD/build/amap-sdk}"
  for part in navi/AMapNaviKit foundation/AMapFoundationKit search/AMapSearchKit; do
    [[ -f "$nav_root/$part.framework/$(basename "$part")" ]] || { echo 'Run setup-amap.mjs first; missing pinned SDK' >&2; exit 2; }
  done
  output=build/navigation/TurboIOPrivateAddon.dylib; mkdir -p build/navigation
  nav_options=(-DTIO_AMAP_ENABLED=1 -F "$nav_root/navi" -F "$nav_root/foundation" -F "$nav_root/search" -framework AMapNaviKit -framework AMapFoundationKit -framework AMapSearchKit -lc++ -lz -lsqlite3 -framework SystemConfiguration -framework CoreTelephony -framework QuartzCore -framework CoreGraphics -framework OpenGLES -framework GLKit -framework CoreMotion -framework AVFoundation -framework AudioToolbox -framework Accelerate -framework Metal -framework CoreText -framework CallKit -framework WebKit)
fi
sdk_path=$(xcrun --sdk iphoneos --show-sdk-path)
link_options=()
# Opt-in diagnostic for the iOS 16 jailbreak injector's chained-fixup stall.
# Keep the normal embedded build unchanged until the device comparison passes.
if [[ ${TIO_CLASSIC_BINDINGS:-1} == 1 ]]; then
  link_options+=(-Wl,-no_fixup_chains)
fi
xcrun --sdk iphoneos clang -arch arm64 -isysroot "$sdk_path" -miphoneos-version-min=16.0 \
  -fobjc-arc -fmodules -dynamiclib -Wall -Wextra -Wno-unused-parameter -Wno-incompatible-pointer-types \
  -framework Foundation -framework UIKit -framework Security -framework UniformTypeIdentifiers -framework CoreLocation \
  ${nav_options[@]+"${nav_options[@]}"} \
  ProtocolContext.m NavigationSubtitleHUD.m NavigationPlaces.m NavigationPlacePicker.m A2UIProtocol.m NavigationCore.m NavigationTeleHUD.m NavigationTransport.m NavigationUI.m ManualHUD.m SubtitleHUDCore.m SubtitleHUD.m \
  "-DTIO_TARGET_BUNDLE_ID=\"$bundle\"" -install_name "$install_name" "${link_options[@]}" \
  Core.m Profile.m KnowledgeClient.m KnowledgeUI.m ProfileUI.m HomeTabLayout.m HomeTabBridge.m ResearchCatalog.m ResearchUI.m NewsPresentation.m PrivateBootstrap.m WebSearch.m TodoProtocol.m TodoRuntime.m NewsCore.m NewsReader.m NewsTeleprompter.m RecordingExports.m RecordingExportsUI.m RecordingExportsMenu.m RecordingText.m RecordingTextUI.m RecordingTextMenu.m AlwaysOnAudioFiles.m AlwaysOnOgg.m AlwaysOnAudioNative.m AlwaysOnAudioUI.m Addon.m -o "$output"
codesign --force --sign - "$output"
plutil -lint TurboIOPrivateAddon.plist
shasum -a 256 "$output"
