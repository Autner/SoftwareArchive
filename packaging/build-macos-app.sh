#!/bin/bash
# 构建 SoftwareArchive 自包含 macOS 应用与 DMG 安装包
# 用法：在仓库根目录执行 bash packaging/build-macos-app.sh
# 产物：packaging/output/SoftwareArchive-<版本>-macOS.dmg
set -e

ROOT=$(cd "$(dirname "$0")/.." && pwd)
VERSION=$(sed -n 's/^SoftwareArchive \([0-9.]*\).*/\1/p' "$ROOT/VERSION.txt" | head -1)
[ -n "$VERSION" ] || { echo "无法从 VERSION.txt 解析版本号"; exit 1; }

APPNAME="软件档案管理"
OUT="$ROOT/packaging/output"
STAGE="$OUT/stage"
APP="$STAGE/dmg/$APPNAME.app"
SA="$APP/Contents/Resources/SoftwareArchive"

rm -rf "$STAGE"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$SA/Work/Scripts" "$SA/Work/Config" "$SA/Library"

# 1) 装入工具本体（源码 + 配置 + 文档，不含任何已收录软件数据）
cp "$ROOT/README.md" "$ROOT/VERSION.txt" "$ROOT/启动软件档案管理.command" "$SA/"
cp "$ROOT/Work/Scripts/"*.sh "$SA/Work/Scripts/"
cp "$ROOT/Work/Config/config.yml" "$SA/Work/Config/"
cp "$ROOT/Library/资源库管理说明.md" "$SA/Library/"
chmod +x "$SA/Work/Scripts/"*.sh "$SA/启动软件档案管理.command"

# 2) 图标（icns）
ICONSET="$STAGE/icon.iconset"
mkdir -p "$ICONSET"
for px in 16 32 64 128 256 512; do
    sips -z $px $px "$ROOT/packaging/icon-512.png" --out "$ICONSET/icon_${px}x${px}.png" >/dev/null
done
cp "$ICONSET/icon_32x32.png" "$ICONSET/icon_16x16@2x.png"
cp "$ICONSET/icon_64x64.png" "$ICONSET/icon_32x32@2x.png"
cp "$ICONSET/icon_256x256.png" "$ICONSET/icon_128x128@2x.png"
cp "$ICONSET/icon_512x512.png" "$ICONSET/icon_256x256@2x.png"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

# 3) 入口程序：代码始终运行自 App 包内；数据保存在 ~/SoftwareArchive（升级/卸载 App 均不影响数据）
cat > "$APP/Contents/MacOS/$APPNAME" <<'EXE'
#!/bin/bash
# 入口：代码在 App 包（Contents/Resources/SoftwareArchive），
#       数据在家目录（默认 ~/SoftwareArchive，可用 SA_HOME 覆盖）。
#       首次运行初始化数据目录；此后每次直接以 SA_DATA_HOME 运行包内代码。
RES="$(cd "$(dirname "$0")/../Resources" && pwd)/SoftwareArchive"
DATA_HOME="${SA_HOME:-$HOME/SoftwareArchive}"
if [ ! -f "$RES/Work/Scripts/SoftwareArchive.sh" ]; then
    osascript -e 'display notification "应用内部文件缺失，请重新下载安装包" with title "软件档案管理" subtitle "启动失败"'
    exit 1
fi
# 首次运行：落一份默认配置（此后永远保留用户配置，升级不覆盖）
if [ ! -f "$DATA_HOME/Work/Config/config.yml" ]; then
    mkdir -p "$DATA_HOME/Work/Config"
    cp "$RES/Work/Config/config.yml" "$DATA_HOME/Work/Config/config.yml"
fi
export SA_DATA_HOME="$DATA_HOME"
(cd "$RES" && bash Work/Scripts/SoftwareArchive.sh -Action Init) >/dev/null 2>&1
[ -n "$SA_SILENT" ] && exit 0
osascript \
  -e 'tell application "Terminal" to activate' \
  -e "tell application \"Terminal\" to do script \"export SA_DATA_HOME='$DATA_HOME'; cd '$RES' && bash './启动软件档案管理.command'\""
EXE
chmod +x "$APP/Contents/MacOS/$APPNAME"

# 4) Info.plist
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key>
	<string>软件档案管理</string>
	<key>CFBundleDisplayName</key>
	<string>软件档案管理</string>
	<key>CFBundleIdentifier</key>
	<string>com.autner.softwarearchive</string>
	<key>CFBundleVersion</key>
	<string>PLACEHOLDER_VERSION</string>
	<key>CFBundleShortVersionString</key>
	<string>PLACEHOLDER_VERSION</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleExecutable</key>
	<string>软件档案管理</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>LSMinimumSystemVersion</key>
	<string>10.13</string>
	<key>NSAppleEventsUsageDescription</key>
	<string>用于在终端中打开管理脚本界面</string>
</dict>
</plist>
PLIST
sed -i '' "s/PLACEHOLDER_VERSION/$VERSION/g" "$APP/Contents/Info.plist"

# 5) DMG 内的说明文件
cat > "$STAGE/dmg/安装说明.txt" <<'NOTE'
软件档案管理（SoftwareArchive）

安装：把「软件档案管理.app」拖入「应用程序」文件夹即完成安装。
使用：双击应用图标，首次运行自动初始化数据目录并打开管理菜单。
结构：工具代码保存在 App 包内部；你的档案数据保存在家目录
     ~/SoftwareArchive（Library 软件档案、Work 配置与缓存）。
升级：直接用新版 App 覆盖旧版即可——数据在家目录，升级、卸载、
     重装 App 均不影响数据。也可用环境变量 SA_HOME 指定其他数据目录。
首次打开若提示无法验证开发者：右键应用 →「打开」。
NOTE

# 6) ad-hoc 签名
codesign --force -s - "$APP"

# 7) 生成 DMG
hdiutil create -volname "SoftwareArchive" \
    -format UDZO \
    -srcfolder "$STAGE/dmg" \
    -ov "$OUT/SoftwareArchive-${VERSION}-macOS.dmg" >/dev/null

echo "打包完成 ✅"
echo "产物: $OUT/SoftwareArchive-${VERSION}-macOS.dmg"
