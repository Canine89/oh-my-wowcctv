#!/bin/zsh
# Oh My WoW CCTV — Developer ID 서명 + 공증 + DMG 생성
# 사용법:
#   scripts/notarize-release.sh            # 빌드 + Developer ID 서명 + DMG (공증 없이 로컬 산출물)
#   scripts/notarize-release.sh --notarize # 위 + 공증 제출/스테이플 (NOTARY_PROFILE 필요)
set -e
cd "$(dirname "$0")/.."

APP="OhMyWowCCTV"
SCHEME="OhMyWowCCTV"
DERIVED="build/DerivedData"
DIST="dist"
SIGN_ID="Developer ID Application: Hyun Gyu Park (M7NU9F8CZN)"
ENTITLEMENTS="Sources/OhMyWowCCTV/OhMyWowCCTV.entitlements"
NOTARY_PROFILE="${NOTARY_PROFILE:-oh-my-opensnap}"

echo "▶ Xcode 프로젝트 생성"
xcodegen generate >/dev/null

echo "▶ Release 빌드"
xcodebuild -project $APP.xcodeproj -scheme $SCHEME -configuration Release \
  -derivedDataPath $DERIVED CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=NO build | tail -3

rm -rf $DIST && mkdir -p $DIST
APP_PATH="$DIST/$APP.app"
cp -R "$DERIVED/Build/Products/Release/$APP.app" "$APP_PATH"

echo "▶ Developer ID 서명 (하드닝 런타임)"
codesign --force --deep --options runtime --timestamp \
  --entitlements "$ENTITLEMENTS" --sign "$SIGN_ID" "$APP_PATH"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
echo "  서명 주체: $(codesign -dvv "$APP_PATH" 2>&1 | grep Authority | head -1)"

VERSION=$(defaults read "$PWD/$APP_PATH/Contents/Info.plist" CFBundleShortVersionString)
DMG="$DIST/OhMyWowCCTV-$VERSION.dmg"

echo "▶ DMG 생성 ($DMG)"
STAGE=$(mktemp -d)
cp -R "$APP_PATH" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Oh My WoW CCTV" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
codesign --force --timestamp --sign "$SIGN_ID" "$DMG"
echo "  DMG 서명 완료"

if [[ "$1" == "--notarize" ]]; then
  echo "▶ 공증 제출 (프로파일: $NOTARY_PROFILE)"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  echo "▶ 스테이플"
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
  spctl -a -t open --context context:primary-signature -vv "$DMG" || true
else
  echo "▶ 공증 건너뜀 (--notarize 로 실행하고 NOTARY_PROFILE 설정 필요)"
fi

echo "✅ 완료: $DMG"
ls -lh "$DMG"
