#!/bin/bash
# 打包 PDF骑缝章.app
set -e
cd "$(dirname "$0")/.."

APP_NAME="PDF骑缝章"
BUNDLE_ID="com.yin.pdfseal"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"

echo "==> Release 编译"
swift build -c release --disable-sandbox

echo "==> 生成图标"
mkdir -p scripts/AppIcon.iconset
swift scripts/make_icon.swift
for s in 16 32 64 128 256 512 1024; do
  sips -z $s $s scripts/AppIcon_1024.png --out scripts/AppIcon.iconset/icon_${s}x${s}.png >/dev/null
  if [ $s -le 512 ]; then
    s=$((s*2))
    sips -z $s $s scripts/AppIcon_1024.png --out scripts/AppIcon.iconset/icon_$((s/2))x$((s/2))@2x.png >/dev/null
  fi
done
iconutil -c icns scripts/AppIcon.iconset -o scripts/AppIcon.icns

echo "==> 组装 bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/PDFSeal "$APP/Contents/MacOS/PDFSeal"
cp scripts/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>PDFSeal</string>
    <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>zh_CN</string>
        <string>zh-Hans</string>
        <string>en</string>
    </array>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleVersion</key><string>2.0.2</string>
    <key>CFBundleShortVersionString</key><string>2.0.2</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
</dict>
</plist>
PLIST

echo "==> Ad-hoc 签名"
codesign --force --deep --sign - "$APP"

echo "==> 生成 release 产物（app / zip / dmg，文件名不带版本号，版本仅记录在 Info.plist）"
mkdir -p release
rm -rf "release/$APP_NAME.app" "release/$APP_NAME.zip" "release/$APP_NAME.dmg" "release/dmg-tmp"
cp -R "$APP" "release/$APP_NAME.app"
cd release
ditto -c -k --keepParent "$APP_NAME.app" "$APP_NAME.zip"
mkdir "$APP_NAME-dmg"
cp -R "$APP_NAME.app" "$APP_NAME-dmg/"
ln -s /Applications "$APP_NAME-dmg/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$APP_NAME-dmg" -ov -format UDZO "$APP_NAME.dmg" >/dev/null
rm -rf "$APP_NAME-dmg"
cd ..

echo "完成: $APP"
echo "release 产物: release/$APP_NAME.app | release/$APP_NAME.zip | release/$APP_NAME.dmg"
