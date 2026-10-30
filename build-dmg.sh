#!/bin/bash
# Packs Kitty Clear into "build/Kitty Clear_<version>_arm64.dmg", the way Kitty Tools is shipped: the app
# beside a shortcut to Applications, on the background scripts/brand-icon.swift draws.
# The window (600 x 400, icons 112, app at 150,205 and Applications at 450,205, to match that
# background) is laid out by the Finder, which macOS lets a script ask only after the user has agreed
# once. When that fails, or with DMG_LAYOUT=0, the image is made all the same, without background and
# positions. arm64 only: so is the Mole that build-app.sh bundles.
# Publishing: a GitHub release on YyAdnBug/kitty-clear tagged v<version> (VERSION in build-app.sh),
# marked latest, with both files attached: the DMG for a first install and the _arm64.zip, which
# Settings › 关于 downloads to upgrade in place (AppUpdate.swift reads releases/latest).
set -euo pipefail
cd "$(dirname "$0")"

./build-app.sh --check
APP="build/Kitty Clear.app"
NAME="Kitty Clear"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
STAGE=build/dmg
DMG="build/${NAME}_${VERSION}_arm64.dmg"

rm -rf "$STAGE" && mkdir -p "$STAGE"
ditto "$APP" "$STAGE/$NAME.app"
ln -s /Applications "$STAGE/Applications"
if [[ "${DMG_LAYOUT:-1}" == 0 ]]; then
    hdiutil create -volname "$NAME" -srcfolder "$STAGE" -format UDZO -ov "$DMG" > /dev/null
else
    mkdir -p "$STAGE/.background" && cp dmg-background.tiff "$STAGE/.background/background.tiff"
    RW=build/rw.dmg
    hdiutil create -volname "$NAME" -srcfolder "$STAGE" -format UDRW -ov "$RW" > /dev/null
    # A volume of the same name still mounted from an earlier run would get the layout instead.
    [[ -d "/Volumes/$NAME" ]] && hdiutil detach "/Volumes/$NAME" -force > /dev/null || true
    MOUNT=$(hdiutil attach "$RW" -readwrite -noverify -noautoopen | awk -F'\t' '/\/Volumes\// {print $NF}')
    osascript << APPLESCRIPT || echo "The Finder did not lay the window out (not allowed to control it?); the image has no background" >&2
tell application "Finder"
    tell disk "$NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, 800, 548}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 112
        set text size of viewOptions to 12
        set background picture of viewOptions to file ".background:background.tiff"
        set position of item "$NAME.app" of container window to {150, 205}
        set position of item "Applications" of container window to {450, 205}
        -- A Finder that shows hidden files draws .background too: park it right of the default window.
        try
            set position of item ".background" of container window to {860, 205}
        end try
        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT
    rm -rf "$MOUNT/.fseventsd" # written by the mount; it would show in a Finder that shows hidden files
    sync
    hdiutil detach "$MOUNT" > /dev/null || hdiutil detach "$MOUNT" -force > /dev/null
    hdiutil convert "$RW" -format UDZO -ov -o "$DMG" > /dev/null
    rm -f "$RW"
fi
hdiutil verify "$DMG" > /dev/null
rm -rf "$STAGE"
# The in-app upgrade unpacks this zip with ditto and takes it only with this signature: try the same
# round trip here, so a release that could not be installed is never published.
ZIP="build/${NAME}_${VERSION}_arm64.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
CHECK=build/zip-check && rm -rf "$CHECK" && ditto -x -k --noacl --noextattr "$ZIP" "$CHECK"
codesign --verify --deep --strict \
    -R '=identifier "com.yy.kitty-clear" and anchor apple generic and certificate leaf[subject.OU] = "HTX9F4KG39"' "$CHECK/$NAME.app"
rm -rf "$CHECK"
echo "$DMG"
echo "$ZIP"
