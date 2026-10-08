// Renders the Vesper app icon (an evening star between API braces) to PNG.
//
//   swift render_icon.swift <out.png> <size> <mac|win> <full|small>
//
// `mac` follows the macOS icon grid (inset rounded body plus drop shadow);
// `win` fills the canvas. `small` drops the braces so 16–32 px stay legible.
// Run scripts/icons/generate_icons.sh rather than calling this directly.
import AppKit

let args = CommandLine.arguments
guard args.count == 5, let px = Int(args[2]) else {
  FileHandle.standardError.write("usage: render_icon.swift out.png size mac|win full|small\n".data(using: .utf8)!)
  exit(64)
}
let outPath = args[1]
let isMac = args[3] == "mac"
let small = args[4] == "small"

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
  NSColor(
    srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
    green: CGFloat((hex >> 8) & 0xFF) / 255,
    blue: CGFloat(hex & 0xFF) / 255,
    alpha: a)
}

/// Four-point sparkle centred on `c`; `pinch` (0–1) controls how thin the arms are.
func sparkle(_ c: CGPoint, _ r: CGFloat, pinch: CGFloat = 0.16) -> NSBezierPath {
  let p = NSBezierPath()
  let k = r * pinch
  p.move(to: CGPoint(x: c.x, y: c.y + r))
  p.curve(to: CGPoint(x: c.x + r, y: c.y), controlPoint1: CGPoint(x: c.x + k, y: c.y + k), controlPoint2: CGPoint(x: c.x + k, y: c.y + k))
  p.curve(to: CGPoint(x: c.x, y: c.y - r), controlPoint1: CGPoint(x: c.x + k, y: c.y - k), controlPoint2: CGPoint(x: c.x + k, y: c.y - k))
  p.curve(to: CGPoint(x: c.x - r, y: c.y), controlPoint1: CGPoint(x: c.x - k, y: c.y - k), controlPoint2: CGPoint(x: c.x - k, y: c.y - k))
  p.curve(to: CGPoint(x: c.x, y: c.y + r), controlPoint1: CGPoint(x: c.x - k, y: c.y + k), controlPoint2: CGPoint(x: c.x - k, y: c.y + k))
  p.close()
  return p
}

/// A curly brace drawn as a stroked path inside `rect`; `left` picks `{` or `}`.
func brace(in rect: CGRect, left: Bool) -> NSBezierPath {
  let p = NSBezierPath()
  let w = rect.width, h = rect.height
  let x0 = rect.minX, y0 = rect.minY
  // Coordinates are written for `{` and mirrored for `}`.
  func pt(_ fx: CGFloat, _ fy: CGFloat) -> CGPoint {
    CGPoint(x: x0 + (left ? fx : 1 - fx) * w, y: y0 + fy * h)
  }
  p.move(to: pt(1.0, 1.0))
  p.curve(to: pt(0.5, 0.86), controlPoint1: pt(0.68, 1.0), controlPoint2: pt(0.5, 0.97))
  p.line(to: pt(0.5, 0.62))
  p.curve(to: pt(0.0, 0.5), controlPoint1: pt(0.5, 0.53), controlPoint2: pt(0.28, 0.5))
  p.curve(to: pt(0.5, 0.38), controlPoint1: pt(0.28, 0.5), controlPoint2: pt(0.5, 0.47))
  p.line(to: pt(0.5, 0.14))
  p.curve(to: pt(1.0, 0.0), controlPoint1: pt(0.5, 0.03), controlPoint2: pt(0.68, 0.0))
  return p
}

let S: CGFloat = 1024  // design canvas; scaled to `px` on export
let rep = NSBitmapImageRep(
  bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
  samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: S, height: S)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSGraphicsContext.current!.imageInterpolation = .high

// Body: macOS grid is an 824 pt rounded square centred on 1024 (radius ≈ 185).
let body = isMac ? CGRect(x: 100, y: 100, width: 824, height: 824) : CGRect(x: 0, y: 0, width: S, height: S)
let radius: CGFloat = isMac ? 185 : 200
let shape = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)

if isMac {
  NSGraphicsContext.saveGraphicsState()
  let shadow = NSShadow()
  shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
  shadow.shadowBlurRadius = 24
  shadow.shadowOffset = NSSize(width: 0, height: -10)
  shadow.set()
  rgb(0x2A2350).setFill()
  shape.fill()
  NSGraphicsContext.restoreGraphicsState()
}

// Night-sky gradient: brand violet at the top fading to deep indigo.
NSGraphicsContext.saveGraphicsState()
shape.addClip()
NSGradient(colors: [rgb(0x9C8CFF), rgb(0x6A58E8), rgb(0x2B2170)], atLocations: [0, 0.45, 1], colorSpace: .sRGB)!
  .draw(in: body, angle: -70)
// Soft horizon glow behind the star.
let glowCenter = CGPoint(x: body.midX, y: body.midY)
NSGradient(colors: [rgb(0xB9AEFF, 0.55), rgb(0xB9AEFF, 0)])!
  .draw(fromCenter: glowCenter, radius: 0, toCenter: glowCenter, radius: body.width * 0.42, options: [])
// Top sheen.
NSGradient(colors: [NSColor.white.withAlphaComponent(0.16), NSColor.white.withAlphaComponent(0)])!
  .draw(in: CGRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2), angle: -90)
NSGraphicsContext.restoreGraphicsState()

let unit = body.width / 824  // keep artwork proportional on the full-bleed canvas

// Braces.
if !small {
  let bw = 118 * unit, bh = 400 * unit
  let gap = 250 * unit
  let stroke = 50 * unit
  for left in [true, false] {
    let x = left ? body.midX - gap - bw / 2 : body.midX + gap - bw / 2
    let path = brace(in: CGRect(x: x, y: body.midY - bh / 2, width: bw, height: bh), left: left)
    path.lineWidth = stroke
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    NSColor.white.withAlphaComponent(0.92).setStroke()
    path.stroke()
  }
}

// The evening star, with a glow, plus a small companion star.
NSGraphicsContext.saveGraphicsState()
let glow = NSShadow()
glow.shadowColor = NSColor.white.withAlphaComponent(0.85)
glow.shadowBlurRadius = 46 * unit
glow.shadowOffset = .zero
glow.set()
NSColor.white.setFill()
let starR = (small ? 300 : 175) * unit
sparkle(CGPoint(x: body.midX, y: body.midY), starR).fill()
NSGraphicsContext.restoreGraphicsState()

let companion = small
  ? CGPoint(x: body.midX + 225 * unit, y: body.midY + 225 * unit)
  : CGPoint(x: body.midX + 108 * unit, y: body.midY + 138 * unit)
NSColor.white.withAlphaComponent(0.9).setFill()
sparkle(companion, (small ? 70 : 42) * unit, pinch: 0.2).fill()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: outPath))
