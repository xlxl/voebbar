#!/bin/bash
set -e

APP_NAME="VOEBBMenu"
APP_DIR="$APP_NAME.app"
BINARY=".build/release/$APP_NAME"

echo "Building release binary..."
swift build -c release 2>&1

echo "Creating app bundle..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

# Copy binary
cp "$BINARY" "$APP_DIR/Contents/MacOS/$APP_NAME"

# Copy icon if available. Defaults to a repo-relative AppIcon.icns;
# override with `ICON_SRC=/path/to/icon.icns ./build_app.sh`.
ICON_SRC="${ICON_SRC:-AppIcon.icns}"
if [ -f "$ICON_SRC" ]; then
    cp "$ICON_SRC" "$APP_DIR/Contents/Resources/AppIcon.icns"
    echo "Icon bundled from: $ICON_SRC"
else
    echo "No icon found at '$ICON_SRC' — building without custom app icon."
fi

# Create Info.plist
cat > "$APP_DIR/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>VOEBBMenu</string>
    <key>CFBundleDisplayName</key>
    <string>VÖBB</string>
    <key>CFBundleIdentifier</key>
    <string>de.voebb.menubar</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleExecutable</key>
    <string>VOEBBMenu</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key>
        <false/>
        <key>NSExceptionDomains</key>
        <dict>
            <key>voebb.de</key>
            <dict>
                <key>NSIncludesSubdomains</key>
                <true/>
                <key>NSExceptionAllowsInsecureHTTPLoads</key>
                <false/>
            </dict>
        </dict>
    </dict>
</dict>
</plist>
PLIST

# Sign with a stable identity when one exists, so the Keychain recognises rebuilds as the SAME
# app and stops re-prompting for the stored passwords/tokens after every deploy. One-time setup:
# Schlüsselbundverwaltung → Zertifikatsassistent → "Ein Zertifikat erstellen …" → Name
# "VOEBBMenu Dev", Typ "Codesignierung". Then click "Immer erlauben" once per Keychain item.
# Override the identity with `SIGN_IDENTITY=... ./build_app.sh`; without a matching identity the
# bundle stays ad-hoc signed (previous behaviour).
# Note: NOT `-v` — a self-signed cert is CSSMERR_TP_NOT_TRUSTED and would be filtered out, but
# codesign happily signs with it locally and only a *stable* identity matters for the Keychain.
SIGN_IDENTITY="${SIGN_IDENTITY:-VOEBBMenu Dev}"
if security find-identity -p codesigning 2>/dev/null | grep -q "\"$SIGN_IDENTITY\""; then
    codesign --force -s "$SIGN_IDENTITY" "$APP_DIR"
    echo "Signed with identity: $SIGN_IDENTITY"
else
    echo "No signing identity '$SIGN_IDENTITY' found — leaving ad-hoc signature (Keychain will re-prompt after deploys)."
fi

echo "App bundle created at: $APP_DIR"

# Deploy to ONE fixed location and run from there. The Keychain's ACL for the stored passwords is
# tied to the trusted application's *launch path* as well as its signature: a stable identity keeps
# rebuilds silent, but a bundle started from a different path counts as a different app and
# re-prompts. So the repo copy is never launched — it is moved to $DEPLOY_DIR, which is the only
# path that ever gets "Immer erlauben". `DEPLOY=0 ./build_app.sh` builds without deploying.
DEPLOY="${DEPLOY:-1}"
DEPLOY_DIR="${DEPLOY_DIR:-/Applications}"
DEPLOY_APP="$DEPLOY_DIR/$APP_DIR"

if [ "$DEPLOY" = "0" ]; then
    echo "DEPLOY=0 — not deploying. Note: launching '$APP_DIR' from here triggers a Keychain prompt"
    echo "(different launch path than $DEPLOY_APP)."
    echo "Launch with: open $APP_DIR"
    exit 0
fi

# Quit the running instance (any path) before replacing the bundle, so we don't end up with two
# status items or a half-swapped bundle.
if pgrep -x "$APP_NAME" > /dev/null; then
    echo "Quitting running $APP_NAME …"
    pkill -x "$APP_NAME" || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        pgrep -x "$APP_NAME" > /dev/null || break
        sleep 0.3
    done
    pgrep -x "$APP_NAME" > /dev/null && echo "Warning: $APP_NAME is still running."
fi

echo "Deploying to $DEPLOY_APP …"
rm -rf "$DEPLOY_APP"
cp -R "$APP_DIR" "$DEPLOY_APP"

# Verify the deployed copy really carries the stable identity — an ad-hoc bundle here would
# re-prompt on every rebuild, which is the whole thing this deploy step exists to prevent.
if codesign --verify --strict "$DEPLOY_APP" 2>/dev/null; then
    echo "Signature OK: $(codesign -dv "$DEPLOY_APP" 2>&1 | grep '^Authority=' | head -1)"
else
    echo "Warning: signature check failed for $DEPLOY_APP (ad-hoc? expect Keychain prompts)."
fi

# Remove the repo copy so there is exactly one launchable bundle — `open VOEBBMenu.app` out of the
# repo is what re-triggers the Keychain prompt.
rm -rf "$APP_DIR"

open "$DEPLOY_APP"
echo "Launched: $DEPLOY_APP"
