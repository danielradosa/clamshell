
import Foundation
import Metal
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AppKit

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments.count > 1
                          ? CommandLine.arguments[1]
                          : "./preview-output")
try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

guard let device = MTLCreateSystemDefaultDevice() else { fatalError("no Metal device") }
let renderer = try FoldRenderer(device: device)

let width = 1440
let height = 900

func makeSyntheticDesktop() -> CGImage {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    )!

    let gradient = CGGradient(
        colorsSpace: colorSpace,
        colors: [
            CGColor(red: 0.10, green: 0.13, blue: 0.32, alpha: 1),
            CGColor(red: 0.42, green: 0.20, blue: 0.45, alpha: 1),
            CGColor(red: 0.85, green: 0.42, blue: 0.35, alpha: 1),
        ] as CFArray,
        locations: [0, 0.55, 1]
    )!
    context.drawLinearGradient(
        gradient, start: CGPoint(x: 0, y: height), end: CGPoint(x: width, y: 0), options: []
    )

    context.setFillColor(CGColor(gray: 0.08, alpha: 0.72))
    context.fill(CGRect(x: 0, y: height - 28, width: width, height: 28))

    func window(_ rect: CGRect, title: CGColor) {
        context.setFillColor(CGColor(gray: 0.14, alpha: 0.96))
        context.fill(rect)
        context.setFillColor(CGColor(gray: 0.22, alpha: 1))
        context.fill(CGRect(x: rect.minX, y: rect.maxY - 26, width: rect.width, height: 26))
        for (index, color) in [
            CGColor(red: 1, green: 0.35, blue: 0.32, alpha: 1),
            CGColor(red: 1, green: 0.75, blue: 0.20, alpha: 1),
            CGColor(red: 0.20, green: 0.80, blue: 0.30, alpha: 1),
        ].enumerated() {
            context.setFillColor(color)
            context.fillEllipse(in: CGRect(x: rect.minX + 12 + CGFloat(index) * 18,
                                           y: rect.maxY - 18, width: 11, height: 11))
        }
        context.setFillColor(title)
        for line in 0..<Int((rect.height - 50) / 22) {
            let inset = CGFloat(line % 3) * 30
            context.fill(CGRect(x: rect.minX + 20 + inset, y: rect.maxY - 56 - CGFloat(line) * 22,
                                width: rect.width - 60 - inset, height: 7))
        }
    }

    window(CGRect(x: 90, y: 150, width: 560, height: 520),
           title: CGColor(gray: 0.55, alpha: 1))
    window(CGRect(x: 700, y: 260, width: 620, height: 420),
           title: CGColor(red: 0.45, green: 0.70, blue: 0.95, alpha: 1))

    context.setFillColor(CGColor(gray: 0.9, alpha: 0.20))
    let dock = CGRect(x: CGFloat(width) / 2 - 260, y: 16, width: 520, height: 64)
    context.fill(dock)
    for index in 0..<8 {
        context.setFillColor(CGColor(
            red: 0.3 + Double(index) * 0.08, green: 0.5, blue: 0.9 - Double(index) * 0.07, alpha: 1
        ))
        context.fill(CGRect(x: dock.minX + 14 + CGFloat(index) * 62, y: dock.minY + 8,
                            width: 48, height: 48))
    }

    return context.makeImage()!
}

func makeTexture(from image: CGImage) -> MTLTexture {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .bgra8Unorm, width: image.width, height: image.height, mipmapped: false
    )
    descriptor.usage = [.shaderRead]
    let texture = device.makeTexture(descriptor: descriptor)!

    let bytesPerRow = image.width * 4
    var data = [UInt8](repeating: 0, count: bytesPerRow * image.height)
    let context = CGContext(
        data: &data, width: image.width, height: image.height, bitsPerComponent: 8,
        bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    )!
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    texture.replace(
        region: MTLRegionMake2D(0, 0, image.width, image.height),
        mipmapLevel: 0, withBytes: data, bytesPerRow: bytesPerRow
    )
    return texture
}

func writePNG(_ texture: MTLTexture, to url: URL) {
    let bytesPerRow = texture.width * 4
    var data = [UInt8](repeating: 0, count: bytesPerRow * texture.height)
    texture.getBytes(
        &data, bytesPerRow: bytesPerRow,
        from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0
    )
    let context = CGContext(
        data: &data, width: texture.width, height: texture.height, bitsPerComponent: 8,
        bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    )!
    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
}

let source = makeTexture(from: makeSyntheticDesktop())

let targetDescriptor = MTLTextureDescriptor.texture2DDescriptor(
    pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false
)
targetDescriptor.usage = [.renderTarget, .shaderRead]
targetDescriptor.storageMode = .shared

let folds: [Double] = [0.0, 0.2, 0.4, 0.6, 0.8, 0.95]
var written = 0

for style in FoldStyle.all {
    for fold in folds {
        let target = device.makeTexture(descriptor: targetDescriptor)!
        renderer.render(source: source, fold: fold, softness: pow(fold, 1.0 / 3.0),
                        style: style, into: target, waitForCompletion: true)
        let name = String(format: "%@-fold-%02d.png", style.id, Int(fold * 100))
        writePNG(target, to: outputDirectory.appendingPathComponent(name))
        written += 1
    }
}

let columns = folds.count
let rows = FoldStyle.all.count
let cellW = width / 3, cellH = height / 3
let sheet = CGContext(
    data: nil, width: cellW * columns, height: cellH * rows, bitsPerComponent: 8,
    bytesPerRow: cellW * columns * 4, space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
)!
sheet.setFillColor(CGColor(gray: 0.05, alpha: 1))
sheet.fill(CGRect(x: 0, y: 0, width: cellW * columns, height: cellH * rows))

for (rowIndex, style) in FoldStyle.all.enumerated() {
    for (columnIndex, fold) in folds.enumerated() {
        let target = device.makeTexture(descriptor: targetDescriptor)!
        renderer.render(source: source, fold: fold, softness: pow(fold, 1.0 / 3.0),
                        style: style, into: target, waitForCompletion: true)
        let bytesPerRow = target.width * 4
        var data = [UInt8](repeating: 0, count: bytesPerRow * target.height)
        target.getBytes(&data, bytesPerRow: bytesPerRow,
                        from: MTLRegionMake2D(0, 0, target.width, target.height), mipmapLevel: 0)
        let cellContext = CGContext(
            data: &data, width: target.width, height: target.height, bitsPerComponent: 8,
            bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )!
        if let cell = cellContext.makeImage() {
            let y = (rows - 1 - rowIndex) * cellH
            sheet.draw(cell, in: CGRect(x: columnIndex * cellW, y: y, width: cellW, height: cellH))
        }
    }
    _ = style
}

if let sheetImage = sheet.makeImage() {
    let url = outputDirectory.appendingPathComponent("contact-sheet.png")
    if let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil) {
        CGImageDestinationAddImage(destination, sheetImage, nil)
        CGImageDestinationFinalize(destination)
        written += 1
    }
}

print("Wrote \(written) images to \(outputDirectory.path)")
print("Rows: \(FoldStyle.all.map(\.name).joined(separator: ", "))")
print("Columns: fold \(folds.map { String(format: "%.2f", $0) }.joined(separator: ", "))")

let benchWidth = 3420, benchHeight = 2224
let benchDescriptor = MTLTextureDescriptor.texture2DDescriptor(
    pixelFormat: .bgra8Unorm, width: benchWidth, height: benchHeight, mipmapped: false
)
benchDescriptor.usage = [.renderTarget, .shaderRead]
benchDescriptor.storageMode = .private
let benchTarget = device.makeTexture(descriptor: benchDescriptor)!

let sourceDescriptor = MTLTextureDescriptor.texture2DDescriptor(
    pixelFormat: .bgra8Unorm, width: benchWidth, height: benchHeight, mipmapped: false
)
sourceDescriptor.usage = [.shaderRead]
sourceDescriptor.storageMode = .private
let benchSource = device.makeTexture(descriptor: sourceDescriptor)!

for _ in 0..<5 {
    renderer.render(source: benchSource, fold: 0.5, softness: 0.8,
                    style: .glacier, into: benchTarget, waitForCompletion: true)
}

let iterations = 120
let benchStart = Date()
for i in 0..<iterations {
    renderer.render(source: benchSource, fold: Double(i) / Double(iterations), softness: 0.8,
                    style: .glacier, into: benchTarget, waitForCompletion: true)
}
let elapsed = Date().timeIntervalSince(benchStart)
let perFrameMs = elapsed / Double(iterations) * 1000

print("")
print("Throughput at \(benchWidth)x\(benchHeight), heaviest style (Glacier):")
print(String(format: "  %.2f ms per frame  =  %.0f fps ceiling", perFrameMs, 1000 / perFrameMs))
print(String(format: "  60fps budget is 16.67 ms, 120fps is 8.33 ms"))
