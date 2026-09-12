#!/bin/bash
# 打包 PDF骑缝章.app
set -e
cd "$(dirname "$0")/.."

APP_NAME="PDF骑缝章"
BUNDLE_ID="com.yin.pdfseal"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"

# 构建前先杀掉可能运行的旧实例，避免 open 激活旧进程、且保证覆盖写入新二进制
pkill -x PDFSeal 2>/dev/null || true

# —— SDK 兼容性规避 ——
# CLT 27.0（2026-09-12 后台自动更新）的默认 SDK(MacOSX27.0) 把 @State 声明为 SwiftUIMacros 宏，
# 但宏插件未随 CommandLineTools 发布，所有 @State 均报
# "external macro implementation type 'SwiftUIMacros.StateMacro' could not be found"。
# 检测到该问题且本机尚存旧 SDK 时，自动改用 MacOSX26.5.sdk（@State 仍为普通 propertyWrapper）。
CUR_SDK=$(xcrun --show-sdk-path 2>/dev/null || true)
SUI_IF="$CUR_SDK/System/Library/Frameworks/SwiftUICore.framework/Modules/SwiftUICore.swiftmodule/arm64e-apple-macos.swiftinterface"
if [ -f "$SUI_IF" ] && grep -q "StateMacro" "$SUI_IF" \
   && ! ls /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/ 2>/dev/null | grep -qi swiftuimacros \
   && [ -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]; then
  export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
  echo "==> 检测到当前 SDK 缺少 SwiftUIMacros 宏插件，改用 MacOSX26.5.sdk"
fi

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
    <key>CFBundleVersion</key><string>2.2.16</string>
    <key>CFBundleShortVersionString</key><string>2.2.16</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>PDF Document</string>
            <key>CFBundleTypeRole</key><string>Editor</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>com.adobe.pdf</string>
            </array>
        </dict>
    </array>
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

echo "==> 注册 LaunchServices（访达「打开方式」列出本 app 的前提）"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "release/$APP_NAME.app"

# 打包完自动打开（用户约定：免手动到路径下打开）
open "release/$APP_NAME.app"
