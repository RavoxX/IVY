#!/bin/bash
# Builds IVY (Release) and packages it as a drag-to-Applications DMG in dist/.
#
# The DMG contains only the app (~a few MB). IVY's local AI (MLX runtime + models,
# ~5.8 GB) is downloaded from the web during the first-run setup ("Install Everything").
#
# Signing:
#   - Uses a "Developer ID Application" identity if one is in your keychain (required to
#     distribute to other Macs), otherwise your "Apple Development" identity (works on
#     your own Macs; others must right-click ▸ Open the first time).
#   - Override with IVY_SIGN_IDENTITY="…".
# Notarization (optional, Developer ID only):
#   xcrun notarytool store-credentials ivy-notary --apple-id … --team-id … --password …
#   IVY_NOTARY_PROFILE=ivy-notary scripts/build_dmg.sh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build"
DIST="$ROOT/dist"
PROJECT="$ROOT/IVY/IVY.xcodeproj"
ENTITLEMENTS="$ROOT/IVY/Config/IVY.entitlements"

echo "▸ Building IVY (Release)…"
xcodebuild -project "$PROJECT" -scheme IVY -configuration Release \
  -destination "platform=macOS,arch=arm64" -derivedDataPath "$BUILD/DerivedData" ARCHS=arm64 build -quiet

APP="$BUILD/DerivedData/Build/Products/Release/IVY.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"

IDENTITY="${IVY_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  IDENTITY="$(security find-identity -v -p codesigning | grep -o '"Developer ID Application[^"]*"' | head -1 | tr -d '"' || true)"
fi
if [[ -n "$IDENTITY" ]]; then
  echo "▸ Signing with: $IDENTITY"
  codesign --force --options runtime --timestamp --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$APP"
else
  IDENTITY="$(security find-identity -v -p codesigning | grep -o '"Apple Development[^"]*"' | head -1 | tr -d '"' || true)"
  echo "▸ No Developer ID found; keeping the Xcode signature (${IDENTITY:-ad hoc})."
fi
codesign --verify --strict "$APP"

echo "▸ Creating DMG…"
STAGE="$(mktemp -d)/IVY"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/Read Me.txt" <<TXT
IVY $VERSION — a private AI assistant for your MacBook notch

1. Drag IVY into Applications and open it.
2. In the setup window click "Install Everything". IVY downloads its local AI
   (MLX runtime, Qwen3 4B, Whisper, Kokoro — about 5.8 GB) once from the web.
   After that local AI runs offline on your Mac. Alternatively, finish setup and
   select Gemini, Claude or OpenAI in Settings > AI with your own API key.
   Cloud text needs no local models; voice still needs Whisper and the runtime.
3. Hold ⌘ + ⌥ to talk to IVY, or hover the notch.

If macOS says the app can't be opened, right-click IVY ▸ Open (builds that
aren't notarized need this once).

https://github.com/RavoxX/IVY
TXT

mkdir -p "$DIST"
DMG="$DIST/IVY-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "IVY $VERSION" -srcfolder "$STAGE" -ov -format UDZO -fs HFS+ "$DMG" -quiet
rm -rf "$(dirname "$STAGE")"

if [[ -n "$IDENTITY" ]]; then
  codesign --force --sign "$IDENTITY" "$DMG"
fi

if [[ -n "${IVY_NOTARY_PROFILE:-}" ]]; then
  echo "▸ Notarizing…"
  xcrun notarytool submit "$DMG" --keychain-profile "$IVY_NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
fi

echo "✓ $DMG ($(du -h "$DMG" | cut -f1), version $VERSION build $BUILD_NUMBER)"
