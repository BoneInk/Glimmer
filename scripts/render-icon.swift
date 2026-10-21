import AppKit
import Foundation

// Render the SVG master through macOS's native SVG representation, with an
// explicit 8-bit RGBA surface so iconutil receives every size in the same format.
guard CommandLine.arguments.count == 3,
      let image = NSImage(contentsOfFile: CommandLine.arguments[1]),
      let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
      ),
      let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    FileHandle.standardError.write(Data("Usage: render-icon SOURCE.svg OUTPUT.png\n".utf8))
    exit(1)
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.imageInterpolation = .high
image.draw(in: NSRect(x: 0, y: 0, width: 1024, height: 1024),
           from: .zero, operation: .copy, fraction: 1)
NSGraphicsContext.restoreGraphicsState()

guard let png = bitmap.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("PNG encoding failed\n".utf8))
    exit(1)
}
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[2]), options: .atomic)
