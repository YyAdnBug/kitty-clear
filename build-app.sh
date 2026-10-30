#!/bin/bash
# Builds "build/Kitty Clear.app" (ad-hoc signed) from the Swift package. `--check` also runs the self-checks.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="build/Kitty Clear.app"
VERSION=0.1.0
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# Moved into place rather than copied over: a KittyClear that is running keeps the file it started from.
cp .build/release/KittyClear "$APP/Contents/MacOS/KittyClear.new"
mv -f "$APP/Contents/MacOS/KittyClear.new" "$APP/Contents/MacOS/KittyClear"
# The helper behind 电池养护. The app copies it to /Library/PrivilegedHelperTools, as root, when the user
# switches that on.
cp .build/release/KittyClearBattery "$APP/Contents/Resources/kittyclear-battery"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns" # regenerate with: swift scripts/brand-icon.swift
# The interface is written in Chinese; this makes the system's own parts (dialog buttons, dates, error
# texts) Chinese too, whatever language the Mac is set to.
mkdir -p "$APP/Contents/Resources/zh-Hans.lproj"
touch "$APP/Contents/Resources/zh-Hans.lproj/Localizable.strings"

# Bundle the Mole CLI (GPL-3.0) so the app works on a Mac that has never installed it: this release,
# fetched from Mole's GitHub the way the in-app upgrade does it (scripts from the tagged source, the two
# Go helpers checked against the release's SHA256SUMS). Homebrew lags behind the releases. To move to a
# newer Mole, change the number and run `./build-app.sh --check`.
MOLE_VERSION=1.65.0
MOLE="build/mole-$MOLE_VERSION"
if [[ ! -x "$MOLE/mole" ]]; then
    RELEASE="https://github.com/tw93/mole/releases/download/V$MOLE_VERSION"
    rm -rf "$MOLE.incoming" && mkdir -p "$MOLE.incoming/source"
    curl -fsSL "https://github.com/tw93/mole/archive/refs/tags/V$MOLE_VERSION.tar.gz" | tar -xz -C "$MOLE.incoming/source" --strip-components 1
    mv "$MOLE.incoming/source/"{mole,bin,lib,LICENSE} "$MOLE.incoming/" && rm -rf "$MOLE.incoming/source"
    SUMS="$(curl -fsSL "$RELEASE/SHA256SUMS")"
    for helper in analyze status; do
        curl -fsSL "$RELEASE/$helper-darwin-arm64" -o "$MOLE.incoming/bin/$helper-go"
        expected="$(awk -v name="$helper-darwin-arm64" '$2 == name { print $1 }' <<< "$SUMS")"
        if [[ -z "$expected" || "$(shasum -a 256 "$MOLE.incoming/bin/$helper-go" | cut -d' ' -f1)" != "$expected" ]]; then
            echo "$helper-darwin-arm64 does not match the release's SHA256SUMS" >&2
            exit 1
        fi
        chmod 755 "$MOLE.incoming/bin/$helper-go"
    done
    mv "$MOLE.incoming" "$MOLE"
fi
rsync -a --delete "$MOLE/" "$APP/Contents/Resources/mole/"
cat > "$APP/Contents/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>zh-Hans</string>
    <key>CFBundleExecutable</key><string>KittyClear</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIdentifier</key><string>com.yy.kitty-clear</string>
    <key>CFBundleName</key><string>Kitty Clear</string>
    <key>CFBundleDisplayName</key><string>Kitty Clear</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSAppleEventsUsageDescription</key><string>Kitty Clear 要请访达把受系统保护的文件夹移到废纸篓，并通过“系统事件”读取和移除登录时打开的项目。</string>
</dict>
</plist>
EOF
# macOS ties what the user has allowed an app (Full Disk Access, asking the Finder, starting at login) to
# its signature, and an ad-hoc signature is a different one after every build. So the app is signed
# with an Apple Development certificate when the keychain has one, as Kitty Tools is. SIGN_IDENTITY
# names another certificate; "-" asks for ad-hoc, which is also what a Mac without a certificate gets.
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2> /dev/null | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1)}"
if ! codesign --force --sign "${IDENTITY:--}" "$APP/Contents/Resources/kittyclear-battery" "$APP" 2> /dev/null; then
    echo "Could not sign as \"$IDENTITY\"; signing ad-hoc instead" >&2
    codesign --force --sign - "$APP/Contents/Resources/kittyclear-battery" "$APP"
fi
touch "$APP" # Finder and the Dock cache icons by modification date
echo "Built $APP with Mole $(sed -n 's/^VERSION="\(.*\)"$/\1/p' "$APP/Contents/Resources/mole/mole")"

# After changing the bundled Mole, make sure the app still understands its output.
if [[ "${1:-}" == "--check" ]]; then
    "$APP/Contents/MacOS/KittyClear" --selfcheck
    "$APP/Contents/MacOS/KittyClear" --selfcheck-clean
fi
