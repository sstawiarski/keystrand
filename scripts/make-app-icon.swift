// Draws the app icon into an AppIcon.appiconset.
// Usage: swift scripts/make-app-icon.swift Keystrand/Resources/Assets.xcassets/AppIcon.appiconset
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: make-app-icon.swift <AppIcon.appiconset>\n".utf8))
    exit(2)
}
let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)

guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { fatalError("sRGB color space unavailable") }

enum Palette {
    static let backgroundTop: UInt32 = 0x252951
    static let backgroundBottom: UInt32 = 0x073E4B
    static let glyphTop: UInt32 = 0xFFFFFF
    static let glyphMiddle: UInt32 = 0xDEF9F3
    static let glyphBottom: UInt32 = 0x69DCC3
}

func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    let components = [
        CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255, alpha,
    ]
    guard let value = CGColor(colorSpace: colorSpace, components: components) else { fatalError("bad color \(hex)") }
    return value
}

func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
    guard let value = CGGradient(colorsSpace: colorSpace, colors: colors as CFArray, locations: locations) else {
        fatalError("cannot create gradient")
    }
    return value
}

func circle(center: CGPoint, radius: CGFloat) -> CGPath {
    CGPath(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2),
           transform: nil)
}

func roundedRect(_ rect: CGRect, radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

/// Join the teeth before rotating so the key reads as one silhouette at every size.
func keyGlyph(small: Bool) -> CGPath {
    let bowCenter = CGPoint(x: -170, y: 0)
    let bowRadius: CGFloat = 150
    let holeRadius: CGFloat = small ? 65 : 76
    let shaftHalf: CGFloat = small ? 48 : 40
    let shaftEnd: CGFloat = 310
    let shaft = roundedRect(CGRect(x: -70, y: -shaftHalf, width: shaftEnd + 70, height: shaftHalf * 2),
                            radius: 18)
    var outline = circle(center: bowCenter, radius: bowRadius).union(shaft)
    let count = small ? 2 : 3
    let toothWidth: CGFloat = small ? 86 : 62
    let gap: CGFloat = small ? 35 : 25

    for index in 0..<count {
        let x = shaftEnd - CGFloat(count - index) * (toothWidth + gap) + gap
        let depth: CGFloat = index == count - 1 ? 96 : 78
        let tooth = roundedRect(CGRect(x: x, y: -shaftHalf - depth, width: toothWidth, height: depth + 20),
                                radius: 12)
        outline = outline.union(tooth)
    }

    outline = outline.subtracting(circle(center: bowCenter, radius: holeRadius))
    var rotation = CGAffineTransform(rotationAngle: -.pi / 4)
    guard let rotated = outline.copy(using: &rotation) else { fatalError("cannot rotate key") }
    let bounds = rotated.boundingBoxOfPath
    var placement = CGAffineTransform(translationX: 512 - bounds.midX, y: 526 - bounds.midY)
    guard let placed = rotated.copy(using: &placement) else { fatalError("cannot position key") }
    return placed
}

/// Shadow geometry is in device pixels, so `scale` converts icon units to pixels.
func drawGlyph(_ glyph: CGPath, in context: CGContext, scale: CGFloat, small: Bool) {
    context.saveGState()
    if !small {
        context.setShadow(offset: CGSize(width: 0, height: -22 * scale), blur: 26 * scale,
                          color: color(0x020E20, alpha: 0.6))
        context.translateBy(x: 0, y: -10)
        context.addPath(glyph)
        context.setFillColor(color(0x4B9D9B))
        context.fillPath()
    }

    context.restoreGState()

    context.saveGState()
    context.addPath(glyph)
    context.clip()
    let bounds = glyph.boundingBoxOfPath
    context.drawLinearGradient(
        gradient([color(Palette.glyphTop), color(Palette.glyphMiddle), color(Palette.glyphBottom)], [0, 0.52, 1]),
        start: CGPoint(x: bounds.minX, y: bounds.maxY),
        end: CGPoint(x: bounds.maxX, y: bounds.minY),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

    guard !small else {
        context.restoreGState()
        return
    }

    // The inverse silhouette shades both the outer edge and the inside of the ring.
    let inverse = CGMutablePath()
    inverse.addRect(CGRect(x: -1024, y: -1024, width: 3072, height: 3072))
    inverse.addPath(glyph)
    context.setShadow(offset: CGSize(width: 0, height: 5 * scale), blur: 9 * scale,
                      color: color(0x155862, alpha: 0.24))
    context.addPath(inverse)
    context.setFillColor(color(0x000000))
    context.fillPath(using: .evenOdd)
    context.restoreGState()

    context.saveGState()
    context.addPath(glyph)
    context.clip()
    context.addPath(glyph)
    context.setStrokeColor(color(0xFFFFFF, alpha: 0.65))
    context.setLineWidth(3)
    context.strokePath()
    context.restoreGState()
}

func drawIcon(pixels: Int) -> CGImage {
    let size = CGFloat(pixels)
    guard let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { fatalError("cannot create \(pixels) px context") }
    context.interpolationQuality = .high
    context.setShouldAntialias(true)
    let scale = size / 1024
    context.scaleBy(x: scale, y: scale)
    let small = pixels <= 32

    let shapeRect = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = roundedRect(shapeRect, radius: 185.4)
    context.saveGState()
    context.addPath(shape)
    context.clip()
    context.drawLinearGradient(gradient([color(Palette.backgroundTop), color(Palette.backgroundBottom)], [0, 1]),
                               start: CGPoint(x: 250, y: 924), end: CGPoint(x: 774, y: 100),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    let indigoGlow = gradient([color(0x9097FA, alpha: 0.40), color(0x9097FA, alpha: 0)], [0, 1])
    context.drawRadialGradient(indigoGlow, startCenter: CGPoint(x: 195, y: 910), startRadius: 0,
                               endCenter: CGPoint(x: 195, y: 910), endRadius: 820, options: [])
    let tealGlow = gradient([color(0x20DDB4, alpha: 0.60), color(0x20DDB4, alpha: 0)], [0, 1])
    context.drawRadialGradient(tealGlow, startCenter: CGPoint(x: 880, y: 160), startRadius: 0,
                               endCenter: CGPoint(x: 880, y: 160), endRadius: 680, options: [])

    drawGlyph(keyGlyph(small: small), in: context, scale: scale, small: small)
    context.restoreGState()

    if !small {
        context.saveGState()
        context.addPath(shape)
        context.clip()
        context.clip(to: CGRect(x: 100, y: 512, width: 824, height: 412))
        context.addPath(roundedRect(shapeRect.insetBy(dx: 0.5 / scale, dy: 0.5 / scale), radius: 185.4))
        context.setStrokeColor(color(0xFFFFFF, alpha: 0.18))
        context.setLineWidth(1 / scale)
        context.strokePath()
        context.restoreGState()
    }

    guard let image = context.makeImage() else { fatalError("cannot render \(pixels) px icon") }
    return image
}

let files: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

for (name, pixels) in files {
    let url = outputDirectory.appendingPathComponent(name)
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { fatalError("cannot write \(url.path)") }
    CGImageDestinationAddImage(destination, drawIcon(pixels: pixels), nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("cannot finalize \(url.path)") }
    print("wrote \(name) (\(pixels) px)")
}
