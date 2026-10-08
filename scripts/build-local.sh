#!/bin/bash
# Fork build: Release, signed with your Apple Development certificate, installed to /Applications.
# A real team signature is what lets macOS enable the fan helper daemon (the helper also only
# talks to a Coucou from its own team) and keeps Keychain access across rebuilds.
# Override with COUCOU_SIGN_IDENTITY / COUCOU_TEAM; no such certificate → ad-hoc (no fan control).
# ponytail: no PHONE_LINK / iCloud / push — those need the original developer's
# team and provisioning profile. Add them back only with your own Apple team.
set -euo pipefail
cd "$(dirname "$0")/../NotchBuddy"
IDENTITY="${COUCOU_SIGN_IDENTITY:-Apple Development: rfitraalamsyah@gmail.com}"
TEAM="${COUCOU_TEAM:-NV4JUUT26B}"
if ! security find-identity -v -p codesigning | grep -qF "$IDENTITY"; then
  echo "warning: no '$IDENTITY' certificate, building ad-hoc (fan control will not work)"
  IDENTITY="-"; TEAM=""
fi
xcodegen
xcodebuild -scheme NotchBuddy -configuration Release -derivedDataPath build \
  CODE_SIGN_IDENTITY="$IDENTITY" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="$TEAM" \
  PROVISIONING_PROFILE_SPECIFIER="" \
  CODE_SIGN_ENTITLEMENTS=Resources/Coucou.entitlements \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS="" \
  build | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
APP=build/Build/Products/Release/Coucou.app
if [ "$IDENTITY" != "-" ]; then
  # The helper lands in the bundle without its team signature: sign it, then re-seal the app.
  codesign --force --options runtime -i fr.louisraille.NotchBuddy.FanHelper -s "$IDENTITY" "$APP/Contents/MacOS/CoucouFanHelper"
  codesign --force --options runtime --preserve-metadata=entitlements,requirements,flags -s "$IDENTITY" "$APP"
fi
pkill -x Coucou || true
sleep 1
rm -rf /Applications/Coucou.app
ditto "$APP" /Applications/Coucou.app
open /Applications/Coucou.app
