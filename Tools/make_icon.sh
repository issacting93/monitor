#!/bin/bash
# make_icon.sh — render the AppIcon PNGs for the macOS Xcode target.
#
# Reuses the icon design from package.sh (orange rounded square + waveform bars)
# and writes every size the asset catalog needs, plus a Contents.json that
# references them. Re-run after changing the design; the art is placeholder-grade
# and can be swapped for custom artwork later.
set -euo pipefail

cd "$(dirname "$0")/.."

OUT="Tape08/Tape08/Assets.xcassets/AppIcon.appiconset"
mkdir -p "${OUT}"

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export DEVELOPER_DIR
SWIFTC="${DEVELOPER_DIR}/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
SDK="${DEVELOPER_DIR}/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"

cat > /tmp/make_icon.swift <<'ICON'
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

let outDir = CommandLine.arguments[1]

for (size, name) in sizes {
    // Draw into an exact-pixel bitmap rep. NSImage.lockFocus() would create a 2x
    // Retina backing store on a Retina Mac, which doubles every PNG and makes
    // actool drop the whole set (wrong dimensions → no Assets.car).
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(size), pixelsHigh: Int(size),
        bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0) else { continue }
    rep.size = NSSize(width: size, height: size)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
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

    NSGraphicsContext.restoreGraphicsState()

    guard let png = rep.representation(using: .png, properties: [:]) else { continue }
    try? png.write(to: URL(fileURLWithPath: outDir).appendingPathComponent(name))
}
ICON

echo "==> Rendering icons into ${OUT}..."
"${SWIFTC}" /tmp/make_icon.swift -o /tmp/make_icon -target "$(uname -m)-apple-macosx14.0" -sdk "${SDK}"
/tmp/make_icon "$(pwd)/${OUT}"
rm -f /tmp/make_icon /tmp/make_icon.swift

cat > "${OUT}/Contents.json" <<'JSON'
{
  "images" : [
    { "idiom" : "mac", "scale" : "1x", "size" : "16x16",   "filename" : "icon_16x16.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "16x16",   "filename" : "icon_16x16@2x.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "32x32",   "filename" : "icon_32x32.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "32x32",   "filename" : "icon_32x32@2x.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "128x128", "filename" : "icon_128x128.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "128x128", "filename" : "icon_128x128@2x.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "256x256", "filename" : "icon_256x256.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "256x256", "filename" : "icon_256x256@2x.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "512x512", "filename" : "icon_512x512.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "512x512", "filename" : "icon_512x512@2x.png" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON

echo "==> Done: ${OUT}"
