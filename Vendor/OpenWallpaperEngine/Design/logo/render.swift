// Rasterises the logo for the asset catalog. Run through build.sh.
//
//   render.swift svg   <in.svg> <out.png> <pixels>            flat SVG -> square PNG
//   render.swift frame <in.png> <out.png> <pixels>            full-bleed icon -> macOS grid
//   render.swift tile  <in.svg> <out.png> <W>x<H> <#rrggbb>   flat SVG centred on a solid tile
//
// `frame` places a full-bleed render (ictool's output) on Apple's macOS icon grid:
// an 824/1024 body centred on the canvas with a soft drop shadow, as pre-26
// macOS icons are drawn. Used for the macOS 14/15 AppIcon.appiconset fallback.
//
// `tile` draws the flat logo centred on an opaque background, for the screen saver
// thumbnail in System Settings. The logo's square canvas is TILE_LOGO times the tile's
// height; the artwork fills about 63% of that canvas, so it stands ~69% of the tile.
import AppKit

let TILE_LOGO: CGFloat = 1.1

func bitmap(_ px: Int, _ pxHigh: Int? = nil, _ draw: (NSRect) -> Void) -> NSBitmapImageRep {
    let h = pxHigh ?? px
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: h, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: h)
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    ctx.imageInterpolation = .high
    NSGraphicsContext.current = ctx
    draw(NSRect(x: 0, y: 0, width: px, height: h))
    NSGraphicsContext.restoreGraphicsState()
    return rep.retagging(with: .sRGB) ?? rep
}

func usage() -> Never {
    FileHandle.standardError.write("""
        usage: render.swift svg|frame <in> <out.png> <pixels>
               render.swift tile <in.svg> <out.png> <W>x<H> <#rrggbb>

        """.data(using: .utf8)!)
    exit(1)
}

/// "#rrggbb" -> sRGB colour.
func color(_ hex: String) -> NSColor? {
    guard hex.count == 7, hex.hasPrefix("#"), let v = UInt32(hex.dropFirst(), radix: 16) else { return nil }
    return NSColor(srgbRed: CGFloat(v >> 16 & 0xFF) / 255, green: CGFloat(v >> 8 & 0xFF) / 255,
                   blue: CGFloat(v & 0xFF) / 255, alpha: 1)
}

let args = CommandLine.arguments
guard args.count >= 5, let image = NSImage(contentsOf: URL(fileURLWithPath: args[2])) else { usage() }
let rep: NSBitmapImageRep
switch args[1] {
case "tile":
    let dims = args[4].split(separator: "x").compactMap { Int($0) }
    guard args.count == 6, dims.count == 2, let bg = color(args[5]) else { usage() }
    rep = bitmap(dims[0], dims[1]) { canvas in
        bg.setFill()
        canvas.fill()
        let side = canvas.height * TILE_LOGO
        let logo = NSRect(x: canvas.midX - side / 2, y: canvas.midY - side / 2, width: side, height: side)
        image.draw(in: logo, from: .zero, operation: .sourceOver, fraction: 1)
    }
case "svg":
    guard args.count == 5, let px = Int(args[4]) else { usage() }
    rep = bitmap(px) { image.draw(in: $0) }
case "frame":
    guard args.count == 5, let px = Int(args[4]) else { usage() }
    rep = bitmap(px) { canvas in
        let unit = canvas.width / 1024
        let body = NSRect(x: 100 * unit, y: 100 * unit, width: 824 * unit, height: 824 * unit)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
        shadow.shadowOffset = NSSize(width: 0, height: -10 * unit)
        shadow.shadowBlurRadius = 20 * unit
        shadow.set()
        image.draw(in: body, from: .zero, operation: .sourceOver, fraction: 1)
    }
default:
    usage()
}
do {
    try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[3]))
} catch {
    FileHandle.standardError.write("\(args[3]): \(error)\n".data(using: .utf8)!)
    exit(1)
}
