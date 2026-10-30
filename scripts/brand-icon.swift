#!/usr/bin/env swift
// App icon generator. Same kitten as Kitty Tools (kitty-tools-macos/macos/brand-icons.swift) and
// Kitty Code (kitty-code/scripts/brand-icon.swift), here peeking over a freshly cleaned card on a
// sky-blue plate.
// Usage, from the repo root:
//   swift scripts/brand-icon.swift
// Writes AppIcon.icns (1024 canvas, 824 body, baked shadow: the macOS icon grid), which
// build-app.sh copies into the bundle, and dmg-background.tiff, the picture behind the icons in the
// disk image build-dmg.sh makes.

import AppKit

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func hex(_ value: UInt32, _ alpha: CGFloat = 1) -> CGColor {
  CGColor(
    srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
    blue: CGFloat(value & 0xFF) / 255, alpha: alpha)
}

let ink = hex(0x3A2530)
let cream = hex(0xFFF5F0)
let pink = hex(0xFF7FA0)
let beans = hex(0xFF9FB8)
let shine = hex(0x2F86E8)
let blueLine = hex(0xB5D8FF)
let pinkLine = hex(0xFFCFDC)

func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

func ellipse(
  _ ctx: CGContext, _ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat, _ color: CGColor
) {
  ctx.setFillColor(color)
  ctx.fillEllipse(in: CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2))
}

func roundRect(
  _ ctx: CGContext, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat,
  _ color: CGColor
) {
  ctx.setFillColor(color)
  ctx.addPath(
    CGPath(
      roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerWidth: r, cornerHeight: r,
      transform: nil))
  ctx.fillPath()
}

/// Filled shape with a same-colour round stroke, which rounds its corners
func rounded(_ ctx: CGContext, _ path: CGPath, _ color: CGColor, round: CGFloat) {
  ctx.setFillColor(color)
  ctx.setStrokeColor(color)
  ctx.setLineWidth(round)
  ctx.setLineJoin(.round)
  ctx.addPath(path)
  ctx.drawPath(using: .fillStroke)
}

/// Ears, nose
func triangle(_ ctx: CGContext, _ points: [CGPoint], _ color: CGColor, round: CGFloat) {
  let path = CGMutablePath()
  path.addLines(between: points)
  path.closeSubpath()
  rounded(ctx, path, color, round: round)
}

/// Four-point sparkle: tips on the axes, edges pulled in toward the centre
func sparkle(_ ctx: CGContext, _ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat, _ color: CGColor) {
  let tips = [point(cx, cy - r), point(cx + r, cy), point(cx, cy + r), point(cx - r, cy)]
  let path = CGMutablePath()
  path.move(to: tips[3])
  for tip in tips { path.addQuadCurve(to: tip, control: point(cx, cy)) }
  path.closeSubpath()
  rounded(ctx, path, color, round: r * 0.16)
}

func mirrored(_ points: [CGPoint]) -> [CGPoint] { points.map { point(1024 - $0.x, $0.y) } }

/// macOS icon shape: superellipse (n = 5), body 824 inside a 1024 canvas
func squircle() -> CGPath {
  let path = CGMutablePath()
  let steps = 256
  for i in 0..<steps {
    let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
    let (x, y) = (cos(t), sin(t))
    let p = point(
      512 + 412 * (x < 0 ? -1 : 1) * pow(abs(x), 0.4), 512 + 412 * (y < 0 ? -1 : 1) * pow(abs(y), 0.4))
    if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
  }
  path.closeSubpath()
  return path
}

/// Sky-blue plate with a soft top-left glow; everything drawn after it is clipped to the plate.
/// `shadowScale` = pixels per design unit (shadow parameters ignore the CTM)
func plate(_ ctx: CGContext, shadowScale: CGFloat) {
  let shape = squircle()
  ctx.saveGState()
  ctx.setShadow(
    offset: CGSize(width: 0, height: -10 * shadowScale), blur: 20 * shadowScale,
    color: hex(0x000000, 0.3))
  ctx.addPath(shape)
  ctx.setFillColor(hex(0x3C96F7))
  ctx.fillPath()
  ctx.restoreGState()
  ctx.addPath(shape)
  ctx.clip()
  let fill = CGGradient(
    colorsSpace: sRGB, colors: [hex(0x86C5FF), hex(0x3C96F7), hex(0x2478DC)] as CFArray,
    locations: [0, 0.55, 1])!
  ctx.drawLinearGradient(fill, start: point(0, 100), end: point(0, 924), options: [])
  let glow = CGGradient(
    colorsSpace: sRGB, colors: [hex(0xFFFFFF, 0.22), hex(0xFFFFFF, 0)] as CFArray,
    locations: [0, 1])!
  ctx.drawRadialGradient(
    glow, startCenter: point(307, 205), startRadius: 0, endCenter: point(307, 205),
    endRadius: 563, options: [])
}

func kitten(_ ctx: CGContext) {
  // Ears
  let ear = [point(352, 392), point(296, 204), point(478, 330)]
  triangle(ctx, ear, ink, round: 32)
  triangle(ctx, mirrored(ear), ink, round: 32)
  let inner = [point(366, 354), point(338, 260), point(426, 320)]
  triangle(ctx, inner, pink, round: 12)
  triangle(ctx, mirrored(inner), pink, round: 12)
  // Head and blush
  ellipse(ctx, 512, 522, 256, 208, ink)
  ellipse(ctx, 352, 568, 30, 16, hex(0xFF7FA0, 0.8))
  ellipse(ctx, 672, 568, 30, 16, hex(0xFF7FA0, 0.8))
  // Eyes look down at the card
  for cx: CGFloat in [424, 600] {
    ellipse(ctx, cx, 500, 56, 60, cream)
    ellipse(ctx, cx + 6, 524, 34, 35, ink)
    ellipse(ctx, cx + 21, 507, 11.5, 11.5, hex(0xFFFFFF))
    ellipse(ctx, cx - 8, 541, 5.5, 5.5, hex(0xFFFFFF, 0.9))
  }
  // Nose and mouth
  triangle(ctx, [point(496, 566), point(528, 566), point(512, 585)], pink, round: 10)
  let mouth = CGMutablePath()
  mouth.move(to: point(490, 594))
  mouth.addQuadCurve(to: point(512, 596), control: point(500, 612))
  mouth.addQuadCurve(to: point(534, 594), control: point(524, 612))
  ctx.setStrokeColor(beans)
  ctx.setLineWidth(8)
  ctx.setLineCap(.round)
  ctx.setLineJoin(.round)
  ctx.addPath(mouth)
  ctx.strokePath()
  // Cleaned card: nothing left on it but the shine
  roundRect(ctx, 168, 614, 688, 440, 60, cream)
  sparkle(ctx, 512, 800, 84, shine)
  sparkle(ctx, 318, 778, 38, blueLine)
  sparkle(ctx, 700, 760, 44, pinkLine)
  sparkle(ctx, 664, 868, 26, blueLine)
  // Paw shadows on the card, then paws and toe beans
  for cx: CGFloat in [386, 638] {
    ellipse(ctx, cx, 652, 70, 13, hex(0xE9C6D0, 0.8))
    ellipse(ctx, cx, 616, 76, 46, ink)
    for (dx, dy) in [(-26.0, 14.0), (0.0, 21.0), (26.0, 14.0)] as [(CGFloat, CGFloat)] {
      ellipse(ctx, cx + dx, 616 + dy, 10, 9, beans)
    }
  }
}

func icon(pixels: Int) -> CGImage {
  let ctx = CGContext(
    data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  // Design space: 1024 units, origin top-left, y down
  let scale = CGFloat(pixels) / 1024
  ctx.translateBy(x: 0, y: CGFloat(pixels))
  ctx.scaleBy(x: scale, y: -scale)
  plate(ctx, shadowScale: scale)
  kitten(ctx)
  return ctx.makeImage()!
}

/// The disk image's window, 600 × 400 points: the app at (150, 205), Applications at (450, 205), an
/// arrow between them (build-dmg.sh puts the icons there). Same layout as Kitty Tools' disk image.
func dmgBackground(scale: Int) -> CGImage {
  let ctx = CGContext(
    data: nil, width: 600 * scale, height: 400 * scale, bitsPerComponent: 8, bytesPerRow: 0,
    space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  ctx.translateBy(x: 0, y: CGFloat(400 * scale))
  ctx.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
  // Cream, with the plate's sky blue glowing in from the top left and the kitten's pink from the bottom right
  ctx.setFillColor(cream)
  ctx.fill(CGRect(x: 0, y: 0, width: 600, height: 400))
  for (color, center, radii) in [
    (hex(0x3C96F7, 0.16), point(30, 0), (20.0, 355.0)),
    (hex(0xFFCFDC, 0.45), point(600, 400), (0, 340)),
  ] {
    let glow = CGGradient(
      colorsSpace: sRGB, colors: [color, color.copy(alpha: 0)!] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(
      glow, startCenter: center, startRadius: radii.0, endCenter: center, endRadius: radii.1,
      options: .drawsBeforeStartLocation)
  }
  // Wordmark and two lines of help, centred; y is the baseline (glyphs are flipped back upright)
  func text(_ string: String, _ font: NSFont, _ color: CGColor, y: CGFloat) {
    let line = CTLineCreateWithAttributedString(
      NSAttributedString(
        string: string,
        attributes: [
          .font: font, NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]))
    ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
    ctx.textPosition = point((600 - CTLineGetTypographicBounds(line, nil, nil, nil)) / 2, y)
    CTLineDraw(line, ctx)
  }
  let rounded = NSFont.systemFont(ofSize: 24, weight: .bold).fontDescriptor.withDesign(.rounded)
  text("Kitty Clear", rounded.flatMap { NSFont(descriptor: $0, size: 24) } ?? .boldSystemFont(ofSize: 24), hex(0x2478DC), y: 62.5)
  // The system font's fallback squeezes 「」 to half width; PingFang SC keeps them full width
  text(
    "把左边的图标拖到「应用程序」文件夹，就装好了", NSFont(name: "PingFangSC-Regular", size: 13)!,
    hex(0x3A2530, 0.62), y: 86)
  text(
    "首次打开被拦下时：系统设置 › 隐私与安全性 › 仍要打开", .systemFont(ofSize: 11), hex(0x3A2530, 0.5),
    y: 366)
  // Dotted arc between the two icons: zero-length dashes with round caps make evenly spaced dots
  let arc = CGMutablePath()
  arc.move(to: point(235, 211))
  arc.addQuadCurve(to: point(355, 213.5), control: point(302, 178))
  ctx.saveGState()
  ctx.setStrokeColor(shine)
  ctx.setLineWidth(4)
  ctx.setLineCap(.round)
  ctx.setLineDash(phase: 0, lengths: [0, 11.1])
  ctx.addPath(arc)
  ctx.strokePath()
  ctx.restoreGState()
  triangle(ctx, [point(362.4, 212.6), point(354.9, 204.3), point(351.1, 213.5)], shine, round: 4)
  return ctx.makeImage()!
}

/// The Finder pins the background to the window's top left corner at one point per point and does not
/// scale it, so a window dragged larger shows white beyond the picture. The canvas is therefore much
/// larger than the 600 × 400 design: cream, with the pink glow carried on past the design's corner.
// ponytail: 2560 × 1600 covers a full-screen window on Apple's displays at their default scaling
// (not the Pro Display XDR); a larger window shows white at the right and bottom.
let dmgCanvas = (width: 2560, height: 1600)

func dmgCanvasImage(scale: Int) -> CGImage {
  let (width, height) = (dmgCanvas.width * scale, dmgCanvas.height * scale)
  let ctx = CGContext(
    data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!  // opaque anyway: no alpha keeps the file small
  ctx.setFillColor(cream)
  ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
  // The glow from dmgBackground (centre (600, 400), radius 340, #FFCFDC at 0.45 → 0), computed per
  // pixel: row 0 of the buffer is the top row
  let pixels = ctx.data!.assumingMemoryBound(to: UInt8.self)
  let (base, tint): ([Double], [Double]) = ([0xFF, 0xF5, 0xF0], [0xFF, 0xCF, 0xDC])
  let s = Double(scale)
  for y in Int(60 * s)..<Int(740 * s) {
    for x in Int(260 * s)..<Int(940 * s) {
      let r = hypot((Double(x) + 0.5) / s - 600, (Double(y) + 0.5) / s - 400)
      let alpha = 0.45 * max(0, 1 - r / 340)
      for c in 0..<3 {
        pixels[y * ctx.bytesPerRow + x * 4 + c] = UInt8((base[c] + (tint[c] - base[c]) * alpha).rounded())
      }
    }
  }
  // CG's origin is bottom left: the design goes at the top
  ctx.draw(
    dmgBackground(scale: scale),
    in: CGRect(x: 0, y: height - 400 * scale, width: 600 * scale, height: 400 * scale))
  return ctx.makeImage()!
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appending(path: "KittyClear.iconset")
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
  for scale in [1, 2] {
    let rep = NSBitmapImageRep(cgImage: icon(pixels: points * scale))
    let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
    try! rep.representation(using: .png, properties: [:])!.write(to: iconset.appending(path: name))
  }
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", root.appending(path: "AppIcon.icns").path]
try! iconutil.run()
iconutil.waitUntilExit()
precondition(iconutil.terminationStatus == 0, "iconutil failed")
print("wrote AppIcon.icns")

// The background at 1x and 2x in one TIFF (72 and 144 dpi; the Finder picks by screen), Deflate
// compressed: most of the canvas is flat colour.
let dmg = CGImageDestinationCreateWithURL(
  root.appending(path: "dmg-background.tiff") as CFURL, "public.tiff" as CFString, 2, nil)!
for scale in [1, 2] {
  CGImageDestinationAddImage(
    dmg, dmgCanvasImage(scale: scale),
    [
      kCGImagePropertyDPIWidth: 72 * scale, kCGImagePropertyDPIHeight: 72 * scale,
      kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: 8],  // 8 = Adobe Deflate
    ] as CFDictionary)
}
precondition(CGImageDestinationFinalize(dmg))
print("wrote dmg-background.tiff")
// With a folder as argument, also the design area as a PNG to look at.
if CommandLine.arguments.count > 1 {
  let preview = URL(fileURLWithPath: CommandLine.arguments[1]).appending(path: "dmg-background@2x.png")
  try! NSBitmapImageRep(cgImage: dmgBackground(scale: 2)).representation(using: .png, properties: [:])!.write(to: preview)
}
