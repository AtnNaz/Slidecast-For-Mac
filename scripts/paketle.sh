#!/bin/bash
# Sunum Modu'nun macOS sürümünü dağıtım için paketler.
#
#   scripts/paketle.sh            testleri çalıştırır, Release derler, dist/ altına .dmg ve .zip yazar
#   scripts/paketle.sh --testsiz  testleri atlar
#
# Uygulama Apple Developer ID ile imzalanmaz (yerel/ad-hoc imza); indirenler ilk açılışta
# Sistem Ayarları > Gizlilik ve Güvenlik > "Yine de Aç" demelidir (README'de anlatılıyor).
set -euo pipefail
cd "$(dirname "$0")/.."

PROJECT=Sunummodu.xcodeproj
SCHEME=Sunummodu
DERIVED=build.noindex
APP="$DERIVED/Build/Products/Release/Sunummodu.app"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

VERSION=$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release -showBuildSettings 2>/dev/null \
  | awk '$1 == "MARKETING_VERSION" { print $3; exit }')
NAME="SunumModu-$VERSION-macOS"
echo "==> Sunum Modu $VERSION"

if [[ "${1:-}" != "--testsiz" ]]; then
  echo "==> Testler"
  xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Debug -derivedDataPath "$DERIVED" -quiet test
fi

echo "==> Release derleniyor"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release -derivedDataPath "$DERIVED" -quiet clean build
codesign --verify --deep --strict "$APP"

echo "==> Paketleniyor"
rm -rf dist
mkdir -p dist
STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT
ditto "$APP" "$STAGING/Sunummodu.app"
ln -s /Applications "$STAGING/Applications"
hdiutil create -quiet -volname "Sunum Modu" -srcfolder "$STAGING" -ov -format UDZO "dist/$NAME.dmg"
ditto -c -k --keepParent "$APP" "dist/$NAME.zip"
(cd dist && shasum -a 256 "$NAME.dmg" "$NAME.zip" > SHA256SUMS.txt)

# Derleme klasöründeki kopya macOS'un Uygulamalar listesinde ikinci bir "Sunum Modu" olarak görünmesin.
"$LSREGISTER" -u "$PWD/$APP" 2>/dev/null || true
"$LSREGISTER" -u "$PWD/$DERIVED/Build/Products/Debug/Sunummodu.app" 2>/dev/null || true

echo "==> Hazır:"
ls -lh dist
