#!/bin/bash
# package.sh — Build monitor.swift into Tape 08.app
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Tape 08"
BUNDLE_ID="com.opxy.tape08"
EXECUTABLE="Tape08"
SOURCES=(Sources/*.swift)
BUILD_DIR=".build"          # a repo-root dir named Tape08/ exists, so build the binary here
APP_DIR="${APP_NAME}.app"
CONTENTS="${APP_DIR}/Contents"
MACOS="${CONTENTS}/MacOS"
RESOURCES="${CONTENTS}/Resources"

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export DEVELOPER_DIR
SWIFTC="${DEVELOPER_DIR}/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
SDK="${DEVELOPER_DIR}/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"

mkdir -p "${BUILD_DIR}"
echo "==> Compiling ${#SOURCES[@]} source file(s)..."
"${SWIFTC}" -O -parse-as-library "${SOURCES[@]}" -o "${BUILD_DIR}/${EXECUTABLE}" \
    -target arm64-apple-macosx14.0 -sdk "${SDK}" -module-name Tape08 2>&1

echo "==> Building ${APP_DIR}..."
rm -rf "${APP_DIR}"
mkdir -p "${MACOS}" "${RESOURCES}"

mv "${BUILD_DIR}/${EXECUTABLE}" "${MACOS}/${EXECUTABLE}"

# Info.plist
cat > "${CONTENTS}/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>TAPE 08</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleExecutable</key>
    <string>${EXECUTABLE}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>TAPE 08 needs microphone access to receive audio from your USB input device.</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>LSUIElement</key>
    <false/>
</dict>
</plist>
PLIST

# Generate app icon (orange circle with waveform bars)
cat > /tmp/gen_icon.swift <<'ICON'
import AppKit

let sizes: [(CGFloat, String)] = [
    (16, "icon_16x16.png"),
    (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),
    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
    (1024, "icon_512x512@2x.png"),
]

let iconsetPath = CommandLine.arguments[1]

for (size, name) in sizes {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext

    let rect = CGRect(x: 0, y: 0, width: size, height: size)
    let radius = size * 0.2
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.addPath(path)
    ctx.setFillColor(CGColor(red: 0xFF/255.0, green: 0x6B/255.0, blue: 0x1F/255.0, alpha: 1))
    ctx.fillPath()

    let inset = size * 0.15
    let inner = rect.insetBy(dx: inset, dy: inset)
    ctx.setFillColor(CGColor(red: 0x26/255.0, green: 0x28/255.0, blue: 0x2B/255.0, alpha: 0.85))
    ctx.fillEllipse(in: inner)

    let barCount = 24
    let barWidth = (inner.width * 0.6) / CGFloat(barCount * 2 - 1)
    let startX = inner.midX - (CGFloat(barCount) * barWidth * 2 - barWidth) / 2
    ctx.setFillColor(CGColor(red: 0xFF/255.0, green: 0x6B/255.0, blue: 0x1F/255.0, alpha: 1))
    for i in 0..<barCount {
        let t = CGFloat(i) / CGFloat(barCount - 1)
        let h = (0.2 + 0.8 * sin(t * .pi)) * inner.height * 0.45
        let x = startX + CGFloat(i) * barWidth * 2
        let y = inner.midY - h / 2
        ctx.fill(CGRect(x: x, y: y, width: barWidth, height: h))
    }

    img.unlockFocus()

    guard let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { continue }
    try? png.write(to: URL(fileURLWithPath: iconsetPath).appendingPathComponent(name))
}
ICON

ICONSET="${RESOURCES}/AppIcon.iconset"
mkdir -p "${ICONSET}"
"${SWIFTC}" /tmp/gen_icon.swift -o /tmp/gen_icon -target arm64-apple-macosx14.0 -sdk "${SDK}" 2>&1
/tmp/gen_icon "${ICONSET}"
iconutil -c icns "${ICONSET}" -o "${RESOURCES}/AppIcon.icns" 2>&1
rm -rf "${ICONSET}" /tmp/gen_icon /tmp/gen_icon.swift

# Entitlements
ENTITLEMENTS="/tmp/Tape08_entitlements.plist"
cat > "${ENTITLEMENTS}" <<ENT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.device.audio-input</key>
    <true/>
</dict>
</plist>
ENT

echo "==> Signing..."
codesign --force --deep --sign - --entitlements "${ENTITLEMENTS}" "${APP_DIR}" 2>&1

echo "==> Done: ${APP_DIR}"
echo "    Open it with: open \"${APP_DIR}\""
