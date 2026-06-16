// Generates Fader's AppIcon.appiconset (vertical mixing faders on a blue squircle).
// Run:  swift scripts/make-icon.swift
import AppKit

let outDir = "Fader/Assets.xcassets/AppIcon.appiconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

func draw(_ size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                              colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // Squircle background with a top-to-bottom blue→indigo gradient.
    let margin = size * 0.085
    let rect = CGRect(x: margin, y: margin, width: size - 2*margin, height: size - 2*margin)
    let radius = rect.width * 0.225
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.saveGState(); ctx.addPath(path); ctx.clip()
    let cs = CGColorSpaceCreateDeviceRGB()
    let grad = CGGradient(colorsSpace: cs, colors: [
        CGColor(red: 0.46, green: 0.55, blue: 1.00, alpha: 1),   // top
        CGColor(red: 0.20, green: 0.32, blue: 0.86, alpha: 1)    // bottom
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: rect.maxY), end: CGPoint(x: 0, y: rect.minY), options: [])
    ctx.restoreGState()

    // Three vertical faders: a translucent track + a white knob at varying heights.
    let knobYs: [CGFloat] = [0.62, 0.40, 0.55]   // fraction up the track
    let trackTop = rect.minY + rect.height * 0.74
    let trackBot = rect.minY + rect.height * 0.26
    let trackW = size * 0.030
    let knobR = size * 0.066
    let cols = 3
    for i in 0..<cols {
        let cx = rect.minX + rect.width * (CGFloat(i) + 1) / CGFloat(cols + 1)
        // track
        let tr = CGRect(x: cx - trackW/2, y: trackBot, width: trackW, height: trackTop - trackBot)
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.34))
        ctx.addPath(CGPath(roundedRect: tr, cornerWidth: trackW/2, cornerHeight: trackW/2, transform: nil)); ctx.fillPath()
        // knob
        let ky = trackBot + (trackTop - trackBot) * knobYs[i]
        let kr = CGRect(x: cx - knobR, y: ky - knobR, width: knobR*2, height: knobR*2)
        ctx.setShadow(offset: .zero, blur: size*0.012, color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.28))
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fillEllipse(in: kr)
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func write(_ size: Int, _ name: String) {
    let rep = draw(CGFloat(size))
    let data = rep.representation(using: .png, properties: [:])!
    try? data.write(to: URL(fileURLWithPath: "\(outDir)/\(name)"))
}

// macOS icon set: (point size, scale) → pixels.
let specs: [(Int, Int)] = [(16,1),(16,2),(32,1),(32,2),(128,1),(128,2),(256,1),(256,2),(512,1),(512,2)]
var images: [[String: String]] = []
for (pt, scale) in specs {
    let px = pt * scale
    let file = "icon_\(pt)x\(pt)@\(scale)x.png"
    write(px, file)
    images.append(["idiom": "mac", "size": "\(pt)x\(pt)", "scale": "\(scale)x", "filename": file])
}

let contents: [String: Any] = ["images": images, "info": ["version": 1, "author": "fader"]]
let json = try! JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted])
try! json.write(to: URL(fileURLWithPath: "\(outDir)/Contents.json"))
print("✅ wrote \(specs.count) icons + Contents.json to \(outDir)")
