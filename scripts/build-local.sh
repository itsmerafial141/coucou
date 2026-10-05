#!/bin/bash
# Fork build: Release, ad-hoc signed, installed to /Applications.
# ponytail: no PHONE_LINK / iCloud / push — those need the original developer's
# team and provisioning profile. Add them back only with your own Apple team.
set -euo pipefail
cd "$(dirname "$0")/../NotchBuddy"
xcodegen
xcodebuild -scheme NotchBuddy -configuration Release -derivedDataPath build \
  CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" \
  PROVISIONING_PROFILE_SPECIFIER="" \
  CODE_SIGN_ENTITLEMENTS=Resources/Coucou.entitlements \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS="" \
  build | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
pkill -x Coucou || true
sleep 1
rm -rf /Applications/Coucou.app
ditto build/Build/Products/Release/Coucou.app /Applications/Coucou.app
open /Applications/Coucou.app
