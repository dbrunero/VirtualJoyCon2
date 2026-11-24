#!/bin/bash
# Doppio clic per (ri)compilare VirtualJoyCon2.app (driver incluso)
set -e
cd "$(dirname "$0")"
APP="VirtualJoyCon2.app"
DEXT="Driver/local.joycon2mac.driver.dext"
OBJ="$(mktemp -d)"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Library/SystemExtensions"
cp Sorgenti/Info.plist "$APP/Contents/Info.plist"
# Icona (Icona/AppIcon.icon, stesso stile di Switchintosh): actool di Xcode la compila
if xcrun actool "$(pwd)/Icona/AppIcon.icon" --compile "$OBJ" --platform macosx --minimum-deployment-target 14.0 \
        --app-icon AppIcon --output-partial-info-plist "$OBJ/icon.plist" > "$OBJ/actool.log" 2>&1; then
    cp "$OBJ/Assets.car" "$OBJ/AppIcon.icns" "$APP/Contents/Resources/"
else
    echo "Icona non compilata (serve Xcode con actool): l'app avrà l'icona generica"
fi
# Driver DriverKit, già firmato con i suoi entitlement: ditto conserva la firma
ditto "$DEXT" "$APP/Contents/Library/SystemExtensions/local.joycon2mac.driver.dext"
# Lettore Wii Remote (da JoyCon2Mac) + ponte verso Swift
for f in WiimoteManager WiiBridge WiimotePairer; do
    clang++ -c -O2 -std=c++17 -fobjc-arc -mmacosx-version-min=14.0 -arch arm64 \
        Sorgenti/$f.mm -o "$OBJ/$f.o"
done
swiftc -O -parse-as-library -target arm64-apple-macos14.0 \
    -import-objc-header Sorgenti/WiiBridge.h \
    -framework IOKit -framework IOBluetooth -framework SwiftUI -framework Foundation \
    -framework SystemExtensions -framework Network -lc++ \
    Sorgenti/VirtualJoyCon2.swift Sorgenti/PhoneLink.swift "$OBJ/WiimoteManager.o" "$OBJ/WiiBridge.o" "$OBJ/WiimotePairer.o" \
    -o "$APP/Contents/MacOS/VirtualJoyCon2"
rm -rf "$OBJ"
# Firma dell'app (non --deep: il driver tiene la sua) col permesso di installare estensioni
codesign -s - -f --entitlements Sorgenti/VirtualJoyCon2.entitlements "$APP"
echo "Fatto: $(pwd)/$APP"
