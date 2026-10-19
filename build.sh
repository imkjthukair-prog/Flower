#!/bin/zsh
# Build the supplied Sources + Resources without consulting the installed original app.
set -euo pipefail
source_dir="${0:A:h}"
app="${1:-$source_dir/outputs/Flower.app}"
resource_dir="${2:-$source_dir/Resources}"
app="${app:A}"
resource_dir="${resource_dir:A}"
if [[ "$app" != *.app ]]; then print -u2 'Output must end in .app'; exit 2; fi
if [[ ! -d "$source_dir/Sources" || ! -d "$resource_dir" ]]; then
  print -u2 'Sources/ and Resources/ are required beside this script (or pass Resources as argument 2).'; exit 2
fi
if [[ "$(uname -m)" != arm64 ]]; then print -u2 'This package contains Apple Silicon helpers and builds on an arm64 Mac.'; exit 2; fi
for required in Tools/ffmpeg PowerPoint/arm64/bin/java PowerPoint/lib/tangerine-powerpoint.jar PagesWriter.js PagesTemplate.pages OfficePreview.js; do
  if [[ ! -f "$resource_dir/$required" ]]; then print -u2 "Missing resource: $required"; exit 2; fi
done
if [[ -e "$app" ]]; then
  existing_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist" 2>/dev/null || true)
  if [[ "$existing_id" != local.flower.app ]]; then print -u2 'Refusing to replace an unrelated existing app or directory.'; exit 2; fi
fi
parent="${app:h}"
mkdir -p "$parent" "$source_dir/.build/module-cache"
module_cache="$source_dir/.build/module-cache"
# Clang caches store absolute paths; use the canonical path if this cache is shared.
module_cache="${module_cache:A}"
nonce=$(/usr/bin/uuidgen)
stage="$parent/.Flower-build-$nonce.app"
backup="$parent/.Flower-backup-$nonce.app"
published=false
cleanup() {
  if [[ "$published" == false && -e "$backup" && ! -e "$app" ]]; then /bin/mv "$backup" "$app"; fi
  if [[ -d "$stage" ]]; then /bin/rm -rf "$stage"; fi
}
trap cleanup EXIT
mkdir -p "$stage/Contents/MacOS"
/usr/bin/ditto "$resource_dir" "$stage/Contents/Resources"
/usr/bin/xcrun swiftc -swift-version 5 -parse-as-library -O \
  -module-cache-path "$module_cache" -target arm64-apple-macosx13.0 \
  "$source_dir"/Sources/*.swift -o "$stage/Contents/MacOS/Flower" \
  -framework AppKit -framework SwiftUI -framework ImageIO -framework AVFoundation \
  -framework PDFKit -framework JavaScriptCore -framework WebKit -framework Vision
cat > "$stage/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Flower</string>
<key>CFBundleDisplayName</key><string>Flower · وردة</string>
<key>CFBundleIdentifier</key><string>local.flower.app</string>
<key>CFBundleExecutable</key><string>Flower</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.2.4</string>
<key>CFBundleVersion</key><string>7</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>CFBundleDocumentTypes</key><array><dict>
<key>CFBundleTypeName</key><string>Convertible Files</string>
<key>CFBundleTypeRole</key><string>Viewer</string>
<key>LSItemContentTypes</key><array><string>public.data</string><string>public.content</string></array>
<key>LSHandlerRank</key><string>Alternate</string>
</dict></array>
</dict></plist>
PLIST
/usr/bin/plutil -lint "$stage/Contents/Info.plist"
/usr/bin/codesign --force --sign - "$stage"
/usr/bin/codesign --verify --deep --strict "$stage"
if [[ -e "$app" ]]; then /bin/mv "$app" "$backup"; fi
/bin/mv "$stage" "$app"
published=true
if [[ -d "$backup" ]]; then /bin/rm -rf "$backup"; fi
print "Built and verified: $app"
