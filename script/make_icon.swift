// Derives a macOS-shaped app icon from a full-bleed square master.
//
// The master in assets/ stays square — that is the fleet rule, and it is what
// iOS, the web and the README want.  macOS before 26 does not mask app icons,
// so a square master shipped as an .icns looks like a sticker next to every
// other icon in the Dock.  This draws the master inside Apple's macOS icon
// grid instead: an 824x824 rounded rectangle with a 185.4 point corner radius,
// centred on a 1024 canvas, with the standard soft drop shadow.  The master
// files are only ever read.
//
// usage: swift script/make_icon.swift <master.png> <output.png>

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let canvas: CGFloat = 1024
let plate: CGFloat = 824
let radius: CGFloat = 185.4
let shadowOffset = CGSize(width: 0, height: -10)
let shadowBlur: CGFloat = 20
let shadowAlpha: CGFloat = 0.30

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("make_icon: \(message)\n".utf8))
    exit(1)
}

let arguments = CommandLine.arguments
guard arguments.count == 3 else { fail("usage: make_icon.swift <master.png> <output.png>") }
let sourceURL = URL(fileURLWithPath: arguments[1])
let outputURL = URL(fileURLWithPath: arguments[2])

guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
      let master = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    fail("could not read master image: \(sourceURL.path)")
}

guard let context = CGContext(
    data: nil,
    width: Int(canvas),
    height: Int(canvas),
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    fail("could not create the drawing context")
}

context.interpolationQuality = .high
context.clear(CGRect(x: 0, y: 0, width: canvas, height: canvas))

// The plate sits centred, and a touch above centre, because the shadow falls
// below it — the same optical centring Apple's own grid uses.
let inset = (canvas - plate) / 2
let plateRect = CGRect(x: inset, y: inset, width: plate, height: plate)
let platePath = CGPath(
    roundedRect: plateRect,
    cornerWidth: radius,
    cornerHeight: radius,
    transform: nil
)

// The shadow is painted by filling the plate shape once with the shadow set,
// then the artwork is drawn clipped to that same shape.  Setting the shadow
// while drawing the image would shadow every opaque pixel of the master.
context.saveGState()
context.setShadow(
    offset: shadowOffset,
    blur: shadowBlur,
    color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: shadowAlpha)
)
context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
context.addPath(platePath)
context.fillPath()
context.restoreGState()

context.saveGState()
context.addPath(platePath)
context.clip()
context.draw(master, in: plateRect)
context.restoreGState()

guard let rendered = context.makeImage() else { fail("could not render the icon") }
guard let destination = CGImageDestinationCreateWithURL(
    outputURL as CFURL,
    UTType.png.identifier as CFString,
    1,
    nil
) else {
    fail("could not create the output file: \(outputURL.path)")
}
CGImageDestinationAddImage(destination, rendered, nil)
guard CGImageDestinationFinalize(destination) else { fail("could not write \(outputURL.path)") }
print("wrote \(outputURL.path)")
