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
cp "$ROOT/README_先读我.md" "$ROOT/VERSION.txt" "$ROOT/启动软件档案管理.command" "$SA/"
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

# 3) 入口程序：代码装在 ~/SoftwareArchive，数据跟随代码；App 只负责安装/升级/启动
cat > "$APP/Contents/MacOS/$APPNAME" <<'EXE'
#!/bin/bash
# 入口：首次运行把工具安装到 ~/SoftwareArchive；
#       之后运行时若 App 内置代码版本更新，则仅同步代码文件（绝不触碰 Library 数据）；
#       最后在 Terminal 中打开主菜单。
RES="$(cd "$(dirname "$0")/../Resources" && pwd)/SoftwareArchive"
DATA_HOME="${SA_HOME:-$HOME/SoftwareArchive}"
if [ ! -f "$RES/Work/Scripts/SoftwareArchive.sh" ]; then
    osascript -e 'display notification "应用内部文件缺失，请重新下载安装包" with title "软件档案管理" subtitle "启动失败"'
    exit 1
fi
ver_of() { sed -n 's/^SoftwareArchive \([0-9][0-9.]*\).*/\1/p' "$1" 2>/dev/null | head -1; }
# BSD sort 无 -V，用 awk 比较点分版本号
vcmp() { awk -v a="$1" -v b="$2" 'BEGIN{split(a,x,".");split(b,y,".");for(i=1;i<=4;i++){if(x[i]+0>y[i]+0){print "gt";exit}if(x[i]+0<y[i]+0){print "lt";exit}}print "eq"}'; }

if [ ! -d "$DATA_HOME/Work/Scripts" ]; then
    # 首次安装：完整拷贝并初始化
    mkdir -p "$DATA_HOME"
    rsync -a "$RES/" "$DATA_HOME/"
    (cd "$DATA_HOME" && bash Work/Scripts/SoftwareArchive.sh -Action Init) >/dev/null 2>&1
    [ -n "$SA_SILENT" ] && exit 0
    osascript -e 'display notification "安装完成，已放置到 ~/SoftwareArchive" with title "软件档案管理"'
else
    BV=$(ver_of "$RES/VERSION.txt"); HV=$(ver_of "$DATA_HOME/VERSION.txt")
    if [ -n "$BV" ] && [ "$(vcmp "$BV" "$HV")" = "gt" ]; then
        # 升级：仅同步代码与文档，保留 Library、Work/Config 及全部缓存数据
        rsync -a "$RES/Work/Scripts/" "$DATA_HOME/Work/Scripts/"
        ditto "$RES/启动软件档案管理.command" "$DATA_HOME/启动软件档案管理.command"
        ditto "$RES/README_先读我.md" "$DATA_HOME/README_先读我.md"
        ditto "$RES/VERSION.txt" "$DATA_HOME/VERSION.txt"
        [ -f "$DATA_HOME/Work/Config/config.yml" ] || ditto "$RES/Work/Config/config.yml" "$DATA_HOME/Work/Config/config.yml"
        [ -n "$SA_SILENT" ] && exit 0
        osascript -e "display notification \"工具已升级到 v$BV（数据不受影响）\" with title \"软件档案管理\""
    fi
fi
[ -n "$SA_SILENT" ] && exit 0
osascript \
  -e 'tell application "Terminal" to activate' \
  -e "tell application \"Terminal\" to do script \"cd '$DATA_HOME' && bash './启动软件档案管理.command'\""
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
使用：双击应用图标。首次运行会把工具自动安装到 ~/SoftwareArchive
     并打开管理菜单；之后双击始终打开该目录。
数据：收录的软件档案保存在 ~/SoftwareArchive/Library，
     与应用本体分离——将来升级 App、甚至删除重装 App 都不会影响数据。
升级：新版本 App 首次运行时自动更新 ~/SoftwareArchive 中的代码，
     Library 数据保持原样。也可用环境变量 SA_HOME 指定其他数据目录。
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
