#!/usr/bin/swift
import AppKit
import CoreGraphics
import CoreFoundation
import Foundation
import Darwin

private enum RenderError: Error, CustomStringConvertible {
  case colorSpace
  case bitmapContext
  case image
  case png
  case gradient
  case iconutil(Int32)

  var description: String {
    switch self {
    case .colorSpace: return "could not create an sRGB color space"
    case .bitmapContext: return "could not create a bitmap context"
    case .image: return "could not render the icon image"
    case .png: return "could not encode a PNG"
    case .gradient: return "could not create a color gradient"
    case .iconutil(let status): return "iconutil exited with status \(status)"
    }
  }
}

private let canvasSize = 1024

private func squirclePath() -> CGPath {
  let path = CGMutablePath()
  path.move(to: CGPoint(x: 285, y: 100))
  path.addLine(to: CGPoint(x: 739, y: 100))
  path.addCurve(
    to: CGPoint(x: 924, y: 285),
    control1: CGPoint(x: 868.5, y: 100),
    control2: CGPoint(x: 924, y: 155.5)
  )
  path.addLine(to: CGPoint(x: 924, y: 739))
  path.addCurve(
    to: CGPoint(x: 739, y: 924),
    control1: CGPoint(x: 924, y: 868.5),
    control2: CGPoint(x: 868.5, y: 924)
  )
  path.addLine(to: CGPoint(x: 285, y: 924))
  path.addCurve(
    to: CGPoint(x: 100, y: 739),
    control1: CGPoint(x: 155.5, y: 924),
    control2: CGPoint(x: 100, y: 868.5)
  )
  path.addLine(to: CGPoint(x: 100, y: 285))
  path.addCurve(
    to: CGPoint(x: 285, y: 100),
    control1: CGPoint(x: 100, y: 155.5),
    control2: CGPoint(x: 155.5, y: 100)
  )
  path.closeSubpath()
  return path
}

private func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1)
  -> CGColor
{
  CGColor(red: red, green: green, blue: blue, alpha: alpha)
}

private func makeMasterImage(colorSpace: CGColorSpace) throws -> CGImage {
  let bitmapInfo = CGBitmapInfo.byteOrder16Big.union(
    CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
  )
  guard let context = CGContext(
    data: nil,
    width: canvasSize,
    height: canvasSize,
    bitsPerComponent: 16,
    bytesPerRow: 0,
    space: colorSpace,
    bitmapInfo: bitmapInfo.rawValue
  ) else {
    throw RenderError.bitmapContext
  }

  context.setAllowsAntialiasing(true)
  context.setShouldAntialias(true)
  context.clear(CGRect(x: 0, y: 0, width: canvasSize, height: canvasSize))

  let body = squirclePath()
  context.saveGState()
  context.setShadow(
    offset: CGSize(width: 0, height: -16),
    blur: 42,
    color: color(0, 0, 0, 0.38)
  )
  context.addPath(body)
  context.setFillColor(color(0, 0, 0))
  context.fillPath()
  context.restoreGState()

  guard let bodyGradient = CGGradient(
    colorsSpace: colorSpace,
    colors: [
      color(0.20784, 0.23137, 0.27451),
      color(0.13333, 0.14902, 0.17647),
    ] as CFArray,
    locations: nil
  ) else {
    throw RenderError.gradient
  }
  guard let topHighlight = CGGradient(
    colorsSpace: colorSpace,
    colors: [color(1, 1, 1, 0.06), color(1, 1, 1, 0)] as CFArray,
    locations: nil
  ) else {
    throw RenderError.gradient
  }
  context.saveGState()
  context.addPath(body)
  context.clip()
  context.drawLinearGradient(
    bodyGradient,
    start: CGPoint(x: 512, y: 924),
    end: CGPoint(x: 512, y: 100),
    options: []
  )
  context.drawLinearGradient(
    topHighlight,
    start: CGPoint(x: 512, y: 924),
    end: CGPoint(x: 512, y: 512),
    options: []
  )
  context.restoreGState()

  context.addPath(body)
  context.setStrokeColor(color(0.035, 0.043, 0.055, 0.48))
  context.setLineWidth(2)
  context.strokePath()

  let innerHighlight = CGMutablePath()
  innerHighlight.move(to: CGPoint(x: 103, y: 737))
  innerHighlight.addCurve(
    to: CGPoint(x: 287, y: 921),
    control1: CGPoint(x: 103, y: 866),
    control2: CGPoint(x: 158, y: 921)
  )
  innerHighlight.addLine(to: CGPoint(x: 737, y: 921))
  innerHighlight.addCurve(
    to: CGPoint(x: 921, y: 737),
    control1: CGPoint(x: 866, y: 921),
    control2: CGPoint(x: 921, y: 866)
  )
  context.addPath(innerHighlight)
  context.setStrokeColor(color(1, 1, 1, 0.12))
  context.setLineWidth(2)
  context.setLineCap(.round)
  context.strokePath()

  let promptLines: [(CGRect, CGFloat)] = [
    (CGRect(x: 250, y: 642, width: 390, height: 54), 0.32),
    (CGRect(x: 250, y: 540, width: 500, height: 54), 0.56),
    (CGRect(x: 250, y: 438, width: 350, height: 54), 0.84),
  ]
  for (rect, opacity) in promptLines {
    let path = CGPath(
      roundedRect: rect,
      cornerWidth: rect.height / 2,
      cornerHeight: rect.height / 2,
      transform: nil
    )
    context.addPath(path)
    context.setFillColor(color(0.88, 0.91, 0.96, opacity))
    context.fillPath()
  }

  let caret = CGPath(
    roundedRect: CGRect(x: 250, y: 244, width: 52, height: 146),
    cornerWidth: 26,
    cornerHeight: 26,
    transform: nil
  )
  let systemBlue = color(0.039, 0.518, 1)
  context.saveGState()
  context.setShadow(offset: .zero, blur: 26, color: color(0.039, 0.518, 1, 0.28))
  context.addPath(caret)
  context.setFillColor(systemBlue)
  context.fillPath()
  context.restoreGState()

  guard let image = context.makeImage() else { throw RenderError.image }
  return image
}

private func pngData(_ image: CGImage) throws -> Data {
  let bitmap = NSBitmapImageRep(cgImage: image)
  guard let data = bitmap.representation(using: .png, properties: [:]) else {
    throw RenderError.png
  }
  return data
}

private func resizedImage(_ source: CGImage, size: Int, colorSpace: CGColorSpace) throws -> CGImage {
  guard let context = CGContext(
    data: nil,
    width: size,
    height: size,
    bitsPerComponent: 16,
    bytesPerRow: 0,
    space: colorSpace,
    bitmapInfo: CGBitmapInfo.byteOrder16Big.union(
      CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
    ).rawValue
  ) else {
    throw RenderError.bitmapContext
  }
  context.interpolationQuality = .high
  context.setShouldAntialias(true)
  context.draw(source, in: CGRect(x: 0, y: 0, width: size, height: size))
  guard let image = context.makeImage() else { throw RenderError.image }
  return image
}

private func renderIcon() throws {
  let fileManager = FileManager.default
  let scriptURL = URL(fileURLWithPath: #filePath).standardizedFileURL
  let projectRoot = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
  let outputURL = projectRoot
    .appendingPathComponent("packaging", isDirectory: true)
    .appendingPathComponent("AppIcon.icns")
  let previewDirectory = fileManager.temporaryDirectory
    .appendingPathComponent("UndoTurn-icon-previews-\(UUID().uuidString)", isDirectory: true)
  let iconsetURL = previewDirectory.appendingPathComponent("AppIcon.iconset", isDirectory: true)
  let generatedIconURL = previewDirectory.appendingPathComponent("AppIcon.icns")

  try fileManager.createDirectory(at: iconsetURL, withIntermediateDirectories: true)
  guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
    throw RenderError.colorSpace
  }
  let master = try makeMasterImage(colorSpace: colorSpace)
  let iconsetEntries: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
  ]
  for (name, size) in iconsetEntries {
    let image = try resizedImage(master, size: size, colorSpace: colorSpace)
    try pngData(image).write(to: iconsetURL.appendingPathComponent(name), options: .atomic)
  }

  let previews = [
    ("icon_16x16.png", "AppIcon-16.png"),
    ("icon_128x128.png", "AppIcon-128.png"),
    ("icon_512x512@2x.png", "AppIcon-1024.png"),
  ]
  for (sourceName, previewName) in previews {
    try fileManager.copyItem(
      at: iconsetURL.appendingPathComponent(sourceName),
      to: previewDirectory.appendingPathComponent(previewName)
    )
  }

  let iconutil = Process()
  iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
  iconutil.arguments = ["-c", "icns", "-o", generatedIconURL.path, iconsetURL.path]
  try iconutil.run()
  iconutil.waitUntilExit()
  guard iconutil.terminationReason == .exit, iconutil.terminationStatus == 0 else {
    throw RenderError.iconutil(iconutil.terminationStatus)
  }

  if fileManager.fileExists(atPath: outputURL.path) {
    _ = try fileManager.replaceItemAt(outputURL, withItemAt: generatedIconURL)
  } else {
    try fileManager.moveItem(at: generatedIconURL, to: outputURL)
  }
  try fileManager.removeItem(at: iconsetURL)

  print("Wrote \(outputURL.path)")
  for (_, previewName) in previews {
    print(previewDirectory.appendingPathComponent(previewName).path)
  }
}

do {
  try renderIcon()
} catch {
  fputs("render-icon: \(error)\n", stderr)
  exit(EXIT_FAILURE)
}
