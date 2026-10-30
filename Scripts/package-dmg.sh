#!/bin/bash
# Build Release MacTiler, refuse ad-hoc, stage DMG, optionally install to /Applications.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

IDENTITY="${CODE_SIGN_IDENTITY:-Apple Development: junmaly@gmail.com (JP9BN6938U)}"
TEAM="${DEVELOPMENT_TEAM:-G2B4QZWQN7}"
DERIVED="${DERIVED_DATA_PATH:-$ROOT/build}"
APP_SRC="$DERIVED/Build/Products/Release/MacTiler.app"
INSTALL_APPS="${INSTALL_TO_APPLICATIONS:-1}"

if command -v xcodegen >/dev/null 2>&1; then
  xcodegen generate
fi

echo "==> xcodebuild Release (identity=$IDENTITY team=$TEAM)"
xcodebuild \
  -scheme MacTiler \
  -configuration Release \
  -derivedDataPath "$DERIVED" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$IDENTITY" \
  DEVELOPMENT_TEAM="$TEAM" \
  build | tee /tmp/mactiler-013-build.log | tail -30

test -d "$APP_SRC"

# Re-sign explicitly so we never ship "Sign to Run Locally" / ad-hoc.
echo "==> codesign force with $IDENTITY"
codesign --force --deep \
  --sign "$IDENTITY" \
  --entitlements Resources/MacTiler.entitlements \
  "$APP_SRC"

SIG=$(codesign -dvvv "$APP_SRC" 2>&1 || true)
echo "$SIG" | egrep 'Authority|TeamIdentifier|Signature|CDHash' || true
if echo "$SIG" | grep -q 'Signature=adhoc'; then
  echo "ERROR: still ad-hoc — refuse to package. Fix signing identity / keychain." >&2
  exit 1
fi
TEAM_GOT=$(echo "$SIG" | awk -F= '/TeamIdentifier=/{print $2; exit}')
if [[ "$TEAM_GOT" != "$TEAM" ]]; then
  echo "ERROR: TeamIdentifier=$TEAM_GOT expected $TEAM" >&2
  exit 1
fi
# Designated Requirement should mention team / certificate, not only cdhash
DR=$(codesign -d -r- "$APP_SRC" 2>&1 || true)
echo "DR: $DR"
if echo "$DR" | grep -q 'cdhash' && ! echo "$DR" | grep -Eq 'certificate|teamid|OU'; then
  echo "WARN: DR looks cdhash-only (ad-hoc style). Continuing only if TeamIdentifier set." >&2
fi

VER=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_SRC/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_SRC/Contents/Info.plist")
mkdir -p dist
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP_SRC" "$STAGE/MacTiler.app"
# Clear quarantine on staged copy
xattr -cr "$STAGE/MacTiler.app" || true
ln -s /Applications "$STAGE/Applications"
DMG="dist/MacTiler-${VER}.dmg"
rm -f "$DMG"
hdiutil create -volname "MacTiler $VER" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
echo "==> DMG $DMG (build $BUILD)"

if [[ "$INSTALL_APPS" == "1" ]]; then
  echo "==> Installing to /Applications/MacTiler.app (quit running first)"
  pkill -x MacTiler 2>/dev/null || true
  sleep 0.5
  rm -rf /Applications/MacTiler.app
  cp -R "$APP_SRC" /Applications/MacTiler.app
  xattr -cr /Applications/MacTiler.app || true
  codesign -dvvv /Applications/MacTiler.app 2>&1 | egrep 'Authority|TeamIdentifier|Signature|CDHash' || true
  echo "Installed. Open once and grant Accessibility if prompted (same Team cover should keep grant)."
fi
