// Draws Bell's app icon. Run: swift Design/AppIcon.swift <output-dir>
// then copy AppIcon.png into Resources/Assets.xcassets/AppIcon.appiconset
// (as AppIcon, AppIcon-Dark and AppIcon-Tinted).
//
// The first version was solid shapes; it read well but felt heavy next to
// the line icons the rest of the home screen uses, so it became a line icon.
//
// Rejected along the way: a monoline bell (read as a notification badge), an
// orb in an arc (read as a face), a ring with an off-centre clapper (read as
// a googly eye) and a ring filled to a level (read as a laughing face).
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let S: CGFloat = 1024
func save(_ name: String, bg: CGColor?, _ draw: (CGContext) -> Void) {
    let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    if let bg { ctx.setFillColor(bg); ctx.fill(CGRect(x: 0, y: 0, width: S, height: S)) }
    // Flip so y runs down, like a design tool.
    ctx.translateBy(x: 0, y: S); ctx.scaleBy(x: 1, y: -1)
    draw(ctx)
    let url = URL(fileURLWithPath: CommandLine.arguments[1] + "/" + name + ".png")
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil); CGImageDestinationFinalize(dest)
}
let black = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
let c = S / 2

// The bell, drawn as a line icon to sit with the user's black home-screen
// set: one 20 pt stroke with round ends, a glyph about 400 pt across, centred,
// the same weight and footprint as those icons (measured, not eyeballed).
// The same three parts as the first, solid version: dome, lip, clapper, each
// separate so it reads as a constructed mark rather than a notification bell.
func stack(_ ctx: CGContext, ink: CGColor) {
    let line: CGFloat = 20
    ctx.setStrokeColor(ink); ctx.setLineWidth(line)
    ctx.setLineCap(.round); ctx.setLineJoin(.round)

    let r: CGFloat = 176, gap: CGFloat = 52, lipHalf: CGFloat = 214, d: CGFloat = 72
    // Height of the whole glyph, stroke included, so it centres optically.
    let total = r + gap + gap + d + line
    let base = S / 2 - total / 2 + line / 2 + r

    let dome = CGMutablePath()
    dome.addArc(center: CGPoint(x: c, y: base), radius: r, startAngle: .pi, endAngle: 0, clockwise: false)
    dome.closeSubpath()
    ctx.addPath(dome); ctx.strokePath()

    let lip = base + gap
    ctx.move(to: CGPoint(x: c - lipHalf, y: lip)); ctx.addLine(to: CGPoint(x: c + lipHalf, y: lip))
    ctx.strokePath()

    ctx.strokeEllipse(in: CGRect(x: c - d / 2, y: lip + gap, width: d, height: d))
}

save("AppIcon", bg: black) { stack($0, ink: white) }
