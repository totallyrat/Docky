#!/bin/bash
# Builds Docky.app, Docky Settings.app and Docky.dmg into ./build.
# Needs only the Xcode Command Line Tools.
#
#   ./build.sh            universal (Apple silicon + Intel) release build + DMG
#   ARCHS=arm64 ./build.sh  faster, native-only build
set -euo pipefail
cd "$(dirname "$0")"

ROOT=$PWD
BUILD=$ROOT/build
OBJ=$BUILD/obj
ASSETS=$BUILD/assets
PRODUCTS=$BUILD/Products
VERSION=$(tr -d "[:space:]" < VERSION)
BUILD_NUMBER=$(date +%Y%m%d%H%M)
MIN_OS=14.0
read -r -a ARCHS <<< "${ARCHS:-arm64 x86_64}"
SDK=$(xcrun --show-sdk-path)

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

mkdir -p "$OBJ" "$ASSETS" "$PRODUCTS"

# ---------------------------------------------------------------- assets
if [[ ! -f $ASSETS/AppIcon.icns || Tools/IconGen.swift -nt $ASSETS/AppIcon.icns ]]; then
    log "Rendering icons"
    swiftc -O Tools/IconGen.swift -o "$OBJ/icongen"
    "$OBJ/icongen" "$ASSETS" >/dev/null
    iconutil -c icns "$ASSETS/AppIcon.iconset" -o "$ASSETS/AppIcon.icns"
    iconutil -c icns "$ASSETS/SettingsIcon.iconset" -o "$ASSETS/SettingsIcon.icns"
fi
if [[ ! -f $ASSETS/Sounds/Radar.wav || Tools/SoundGen.swift -nt $ASSETS/Sounds/Radar.wav ]]; then
    log "Synthesizing alert sounds"
    swiftc -O Tools/SoundGen.swift -o "$OBJ/soundgen"
    "$OBJ/soundgen" "$ASSETS/Sounds" >/dev/null
fi

# ---------------------------------------------------------------- compile
SHARED=(Sources/Shared/*.swift)
ISLAND_SOURCES=()
while IFS= read -r f; do ISLAND_SOURCES+=("$f"); done < <(find Sources/Docky -name '*.swift' | sort)
SETTINGS_UI=(Sources/SettingsUI/*.swift)
SETTINGS_SOURCES=(Sources/DockySettings/*.swift)

island_bins=(); settings_bins=(); bridge_bins=()
for arch in "${ARCHS[@]}"; do
    log "Compiling Docky ($arch)"
    swiftc -swift-version 5 -O -whole-module-optimization -sdk "$SDK" -target "$arch-apple-macos$MIN_OS" \
        ${SWIFT_FLAGS:-} "${SHARED[@]}" "${SETTINGS_UI[@]}" "${ISLAND_SOURCES[@]}" -o "$OBJ/Docky-$arch"
    island_bins+=("$OBJ/Docky-$arch")

    log "Compiling Docky Settings ($arch)"
    swiftc -swift-version 5 -O -whole-module-optimization -parse-as-library -sdk "$SDK" -target "$arch-apple-macos$MIN_OS" \
        ${SWIFT_FLAGS:-} "${SHARED[@]}" "${SETTINGS_UI[@]}" "${SETTINGS_SOURCES[@]}" -o "$OBJ/DockySettings-$arch"
    settings_bins+=("$OBJ/DockySettings-$arch")

    log "Compiling media bridge ($arch)"
    clang -fobjc-arc -O2 -Wall -arch "$arch" -mmacosx-version-min=$MIN_OS -isysroot "$SDK" \
        -dynamiclib -framework Foundation -install_name @rpath/DockyMediaBridge.dylib \
        Sources/MediaBridge/MediaBridge.m -o "$OBJ/DockyMediaBridge-$arch.dylib"
    bridge_bins+=("$OBJ/DockyMediaBridge-$arch.dylib")
done

# ---------------------------------------------------------------- bundles
write_plist() { # path executable identifier name icon is_agent
    local agent=""
    [[ $6 == yes ]] && agent="<key>LSUIElement</key><true/>
    <key>NSCalendarsFullAccessUsageDescription</key><string>Docky shows your upcoming events in the island's Calendar tab.</string>
    <key>NSCalendarsUsageDescription</key><string>Docky shows your upcoming events in the island's Calendar tab.</string>
    <key>NSBluetoothAlwaysUsageDescription</key><string>Docky shows when AirPods and other Bluetooth devices connect.</string>
    <key>NSFocusStatusUsageDescription</key><string>Docky shows when a Focus turns on or off.</string>
    <key>NSAppleEventsUsageDescription</key><string>Docky pauses your music app when something else starts playing.</string>"
    cat > "$1" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>$2</string>
    <key>CFBundleIdentifier</key><string>$3</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>$4</string>
    <key>CFBundleDisplayName</key><string>$4</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>CFBundleIconFile</key><string>$5</string>
    <key>LSMinimumSystemVersion</key><string>$MIN_OS</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSSupportsAutomaticTermination</key><false/>
    <key>NSHumanReadableCopyright</key><string>Made with care on a Mac.</string>
    $agent
</dict>
</plist>
PLIST
}

ISLAND_APP=$PRODUCTS/Docky.app
SETTINGS_APP="$PRODUCTS/Docky Settings.app"
rm -rf "$ISLAND_APP" "$SETTINGS_APP"

log "Assembling Docky.app"
mkdir -p "$ISLAND_APP/Contents/MacOS" "$ISLAND_APP/Contents/Resources/Sounds" "$ISLAND_APP/Contents/Frameworks"
lipo -create "${island_bins[@]}" -output "$ISLAND_APP/Contents/MacOS/Docky"
lipo -create "${bridge_bins[@]}" -output "$ISLAND_APP/Contents/Frameworks/DockyMediaBridge.dylib"
cp "$ASSETS/AppIcon.icns" "$ISLAND_APP/Contents/Resources/AppIcon.icns"
cp "$ASSETS"/Sounds/*.wav "$ISLAND_APP/Contents/Resources/Sounds/"
write_plist "$ISLAND_APP/Contents/Info.plist" Docky com.totallyrat.docky Docky AppIcon yes
printf 'APPL????' > "$ISLAND_APP/Contents/PkgInfo"

log "Assembling Docky Settings.app"
mkdir -p "$SETTINGS_APP/Contents/MacOS" "$SETTINGS_APP/Contents/Resources/Sounds"
lipo -create "${settings_bins[@]}" -output "$SETTINGS_APP/Contents/MacOS/Docky Settings"
cp "$ASSETS/SettingsIcon.icns" "$SETTINGS_APP/Contents/Resources/SettingsIcon.icns"
cp "$ASSETS"/Sounds/*.wav "$SETTINGS_APP/Contents/Resources/Sounds/"
write_plist "$SETTINGS_APP/Contents/Info.plist" "Docky Settings" com.totallyrat.docky.settings "Docky Settings" SettingsIcon no
printf 'APPL????' > "$SETTINGS_APP/Contents/PkgInfo"

# A stable signing identity lets macOS remember permissions (Accessibility, Calendar…)
# across rebuilds. Create one with Tools/make-signing-identity.sh; otherwise sign ad hoc.
IDENTITY=${SIGN_IDENTITY:-}
if [[ -z $IDENTITY ]] && security find-certificate -c "Docky Local Signing" >/dev/null 2>&1; then
    IDENTITY="Docky Local Signing"
fi
log "Signing (${IDENTITY:-ad hoc})"
codesign --force --sign "${IDENTITY:--}" --timestamp=none "$ISLAND_APP/Contents/Frameworks/DockyMediaBridge.dylib"
codesign --force --sign "${IDENTITY:--}" --timestamp=none "$ISLAND_APP"
codesign --force --sign "${IDENTITY:--}" --timestamp=none "$SETTINGS_APP"

# ---------------------------------------------------------------- dmg
if [[ ${SKIP_DMG:-0} != 1 ]]; then
    log "Packaging Docky.dmg"
    STAGE=$BUILD/dmg-stage
    rm -rf "$STAGE" "$BUILD/Docky.dmg"
    mkdir -p "$STAGE"
    ditto "$ISLAND_APP" "$STAGE/Docky.app"
    ditto "$SETTINGS_APP" "$STAGE/Docky Settings.app"
    ln -s /Applications "$STAGE/Applications"
    hdiutil create -quiet -volname "Docky" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$BUILD/Docky.dmg"
    rm -rf "$STAGE"
    log "Done: $BUILD/Docky.dmg"
else
    log "Done: $PRODUCTS"
fi
