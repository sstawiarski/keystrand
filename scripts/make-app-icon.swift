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
    static let backgroundTop: UInt32 = 0x3A3A8C
    static let backgroundBottom: UInt32 = 0x0D6F7E
    static let glyphTop: UInt32 = 0xFFFFFF
    static let glyphBottom: UInt32 = 0xD3E3F1
    static let cellTop: UInt32 = 0xA8F5E6
    static let cellBottom: UInt32 = 0x5FD3C4
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

struct KeyGlyph {
    var body: CGPath
    var cells: CGPath

    var outline: CGPath { body.union(cells) }

    func applying(_ transform: CGAffineTransform) -> KeyGlyph {
        var transform = transform
        guard let body = body.copy(using: &transform), let cells = cells.copy(using: &transform) else {
            fatalError("cannot transform key")
        }
        return KeyGlyph(body: body, cells: cells)
    }
}

/// A key laid along the x axis: a ring bow on the left, a shaft, and a row of square cells forming the bit.
/// Small renders join two heavier cells to a thicker shaft so the silhouette survives at 16 px.
func keyGlyph(small: Bool) -> KeyGlyph {
    let bowCenter = CGPoint(x: -180, y: 0)
    let bowRadius: CGFloat = 150
    let holeRadius: CGFloat = small ? 56 : 72
    let shaftHalf: CGFloat = small ? 44 : 36
    let shaftStart = bowCenter.x + bowRadius - 40
    let shaftEnd: CGFloat = 300

    let shaft = roundedRect(CGRect(x: shaftStart, y: -shaftHalf, width: shaftEnd - shaftStart, height: shaftHalf * 2),
                            radius: shaftHalf * 0.5)
    let body = circle(center: bowCenter, radius: bowRadius).union(shaft)
        .subtracting(circle(center: bowCenter, radius: holeRadius))

    let cellSide: CGFloat = small ? 80 : 70
    let cellGap: CGFloat = small ? 24 : 18
    let cellDrop: CGFloat = small ? -8 : 12
    let count = small ? 2 : 3
    let cells = CGMutablePath()
    for index in 0..<count {
        let x = shaftEnd - CGFloat(count - index) * (cellSide + cellGap) + cellGap
        let rect = CGRect(x: x, y: -shaftHalf - cellDrop - cellSide, width: cellSide, height: cellSide)
        cells.addPath(roundedRect(rect, radius: small ? 10 : 14))
    }

    return KeyGlyph(body: body, cells: cells)
}

/// The key scaled up and centred on the canvas.
func placedKey(small: Bool) -> KeyGlyph {
    let scaled = keyGlyph(small: small).applying(CGAffineTransform(scaleX: 1.14, y: 1.14))
    let bounds = scaled.outline.boundingBoxOfPath
    return scaled.applying(CGAffineTransform(translationX: 512 - bounds.midX, y: 512 - bounds.midY))
}

func fill(_ path: CGPath, top: UInt32, bottom: UInt32, in context: CGContext) {
    context.saveGState()
    context.addPath(path)
    context.clip()
    let bounds = path.boundingBoxOfPath
    context.drawLinearGradient(gradient([color(top), color(bottom)], [0, 1]),
                               start: CGPoint(x: bounds.minX, y: bounds.maxY),
                               end: CGPoint(x: bounds.maxX, y: bounds.minY),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    context.restoreGState()
}

/// Shadow geometry is in device pixels, so `scale` converts icon units to pixels.
func drawGlyph(_ glyph: KeyGlyph, in context: CGContext, scale: CGFloat, small: Bool) {
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -16 * scale), blur: 30 * scale,
                      color: color(0x061A2E, alpha: small ? 0.25 : 0.35))
    context.beginTransparencyLayer(auxiliaryInfo: nil)
    fill(glyph.body, top: Palette.glyphTop, bottom: Palette.glyphBottom, in: context)
    if small {
        fill(glyph.cells, top: Palette.glyphTop, bottom: Palette.glyphBottom, in: context)
    } else {
        fill(glyph.cells, top: Palette.cellTop, bottom: Palette.cellBottom, in: context)
    }

    context.endTransparencyLayer()
    context.restoreGState()

    guard !small else { return }
    // Inner shadow along the lower edges: the area outside the glyph casts an upward shadow into it.
    let outline = glyph.outline
    context.saveGState()
    context.addPath(outline)
    context.clip()
    let inverse = CGMutablePath()
    inverse.addRect(CGRect(x: -1024, y: -1024, width: 3072, height: 3072))
    inverse.addPath(outline)
    context.setShadow(offset: CGSize(width: 0, height: 10 * scale), blur: 16 * scale,
                      color: color(0x0B3550, alpha: 0.30))
    context.addPath(inverse)
    context.setFillColor(color(0x000000))
    context.fillPath(using: .evenOdd)
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
    let glow = gradient([color(0xFFFFFF, alpha: 0.22), color(0xFFFFFF, alpha: 0)], [0, 1])
    context.drawRadialGradient(glow, startCenter: CGPoint(x: 300, y: 800), startRadius: 0,
                               endCenter: CGPoint(x: 300, y: 800), endRadius: 520, options: [])

    drawGlyph(placedKey(small: small), in: context, scale: scale, small: small)
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
