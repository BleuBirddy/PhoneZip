// Draws the app icon: a zipper opening into a V, with fabric tape, stitching,
// a rounded slider and a pull tab hanging over the closed teeth.
// Run from the repo root:  swift Tools/make-icon.swift
// Writes PhoneZip/Assets.xcassets/AppIcon.appiconset/AppIcon.png (1024x1024).
// iOS rounds the corners itself, so the image is a plain opaque square.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func rgb(_ hex: Int) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

// The two chosen colors, plus shades of each. With only #69021E on #1F251F
// the zipper is hard to see at Home Screen size, so the gap is darker, the
// tape lighter, and each metal part gets a lighter top edge.
let fabric = rgb(0x1F251F)
let tape = rgb(0x283028)
let stitch = rgb(0x85213C)    // a step lighter than the zipper red
let gap = rgb(0x0E120E)
let metal = rgb(0x69021E)
let shine = rgb(0x93183A)

let size = 1024
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!

// Coordinates below are written top-down (y = 0 at the top), like a design tool.
ctx.translateBy(x: 0, y: CGFloat(size))
ctx.scaleBy(x: 1, y: -1)

ctx.setFillColor(fabric)
ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))

let center: CGFloat = 512
let junction: CGFloat = 470          // where the two sides meet, under the slider
let splay: CGFloat = 20              // degrees each open side leans out
let toothW: CGFloat = 78, toothH: CGFloat = 22, step: CGFloat = 40
let tapeW: CGFloat = 120

func roundedRect(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func tooth(_ rect: CGRect) {
    ctx.setFillColor(metal)
    ctx.addPath(roundedRect(rect, 7)); ctx.fillPath()
    ctx.setFillColor(shine)
    ctx.addPath(roundedRect(CGRect(x: rect.minX + 4, y: rect.minY + 2, width: rect.width - 8, height: 6), 3))
    ctx.fillPath()
}

func stitchLine(x: CGFloat, from y0: CGFloat, to y1: CGFloat) {
    ctx.setStrokeColor(stitch)
    ctx.setLineWidth(6)
    ctx.setLineCap(.round)
    ctx.setLineDash(phase: 0, lengths: [22, 18])
    ctx.move(to: CGPoint(x: x, y: y0)); ctx.addLine(to: CGPoint(x: x, y: y1))
    ctx.strokePath()
    ctx.setLineDash(phase: 0, lengths: [])
}

// The dark gap inside the V, behind everything else.
let reach: CGFloat = 640
let lean = sin(splay * .pi / 180) * reach, rise = cos(splay * .pi / 180) * reach
let opening = CGMutablePath()
opening.move(to: CGPoint(x: center - 30, y: junction))
opening.addLine(to: CGPoint(x: center - 30 - lean, y: junction - rise))
opening.addLine(to: CGPoint(x: center + 30 + lean, y: junction - rise))
opening.addLine(to: CGPoint(x: center + 30, y: junction))
opening.closeSubpath()
ctx.setFillColor(gap)
ctx.addPath(opening); ctx.fillPath()

// One open side, drawn upright in its own frame and then leaned out.
// `out` is -1 for the left side, +1 for the right; teeth sit on the inner edge.
func openSide(out: CGFloat) {
    ctx.saveGState()
    ctx.translateBy(x: center + out * 30, y: junction)
    // The y axis is flipped, so a negative angle leans the left side left.
    ctx.rotate(by: out * splay * .pi / 180)
    let tapeX = out < 0 ? -tapeW - 40 : 40
    ctx.setFillColor(tape)
    ctx.fill(CGRect(x: tapeX, y: -reach, width: tapeW, height: reach))
    stitchLine(x: out * (tapeW + 10), from: -reach, to: 0)
    for k in 0..<16 {
        let y = -40 - CGFloat(k) * step - (out > 0 ? step / 2 : 0)
        tooth(CGRect(x: out < 0 ? -toothW + 10 : -10, y: y, width: toothW, height: toothH))
    }
    ctx.restoreGState()
}
// Clipped at the junction so the leaning tapes don't poke below it.
ctx.saveGState()
ctx.clip(to: CGRect(x: 0, y: 0, width: CGFloat(size), height: junction))
openSide(out: -1)
openSide(out: 1)
ctx.restoreGState()

// Closed part, below the slider: tape on both sides, teeth interlocking.
// Its top flares out to meet the leaning tapes where they were clipped.
let half = toothW + 70
let flare = 40 + tapeW / cos(splay * .pi / 180)
let closedTape = CGMutablePath()
closedTape.move(to: CGPoint(x: center - 30 - flare, y: junction))
closedTape.addLine(to: CGPoint(x: center + 30 + flare, y: junction))
closedTape.addLine(to: CGPoint(x: center + half, y: junction + 110))
closedTape.addLine(to: CGPoint(x: center + half, y: CGFloat(size)))
closedTape.addLine(to: CGPoint(x: center - half, y: CGFloat(size)))
closedTape.addLine(to: CGPoint(x: center - half, y: junction + 110))
closedTape.closeSubpath()
ctx.setFillColor(tape)
ctx.addPath(closedTape); ctx.fillPath()
stitchLine(x: center - toothW - 50, from: junction + 110, to: CGFloat(size))
stitchLine(x: center + toothW + 50, from: junction + 110, to: CGFloat(size))
for k in 0..<15 {
    let y = junction + CGFloat(k) * step
    tooth(CGRect(x: center - toothW + 6, y: y, width: toothW, height: toothH))
    tooth(CGRect(x: center - 6, y: y + step / 2, width: toothW, height: toothH))
}

// Slider: a rounded cap over the junction.
let cap = roundedRect(CGRect(x: center - 82, y: 400, width: 164, height: 190), 70)
ctx.setFillColor(metal); ctx.addPath(cap); ctx.fillPath()
ctx.setFillColor(shine)
ctx.addPath(roundedRect(CGRect(x: center - 60, y: 412, width: 120, height: 14), 7)); ctx.fillPath()
// The bridge the tab hooks onto.
ctx.setFillColor(gap)
ctx.addPath(roundedRect(CGRect(x: center - 22, y: 450, width: 44, height: 90), 22)); ctx.fillPath()
ctx.setFillColor(metal)
ctx.addPath(roundedRect(CGRect(x: center - 12, y: 450, width: 24, height: 90), 12)); ctx.fillPath()

// Pull tab hanging over the closed teeth. A fabric-colored outline separates
// it from the teeth and slider so it reads as its own piece.
let tab = roundedRect(CGRect(x: center - 58, y: 540, width: 116, height: 300), 34)
ctx.addPath(tab)
ctx.setStrokeColor(gap); ctx.setLineWidth(24); ctx.strokePath()
ctx.setFillColor(metal); ctx.addPath(tab); ctx.fillPath()
ctx.setFillColor(shine)
ctx.addPath(roundedRect(CGRect(x: center - 40, y: 548, width: 80, height: 10), 5)); ctx.fillPath()
// Slot near the top of the tab.
ctx.setFillColor(gap)
ctx.addPath(roundedRect(CGRect(x: center - 20, y: 580, width: 40, height: 74), 20)); ctx.fillPath()

let out = URL(fileURLWithPath: "PhoneZip/Assets.xcassets/AppIcon.appiconset/AppIcon.png")
try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("Couldn't write \(out.path)") }
print("Wrote \(out.path)")
