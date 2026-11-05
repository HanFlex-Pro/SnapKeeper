// test/fixtures/의 EXIF 테스트 이미지를 만든다. macOS에서 실행:
//   swiftc tool/make_test_fixtures.swift -o /tmp/fixtures && /tmp/fixtures test/fixtures
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let out = CommandLine.arguments[1]
let w = 64, h = 32
var pixels = [UInt8](repeating: 200, count: w * h * 4)
let ctx = CGContext(
  data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
  space: CGColorSpace(name: CGColorSpace.sRGB)!,
  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
let image = ctx.makeImage()!

func save(_ name: String, _ type: UTType, exif: Bool, gps: (Double, String, Double, String)? = nil) {
  let dest = CGImageDestinationCreateWithURL(
    URL(fileURLWithPath: "\(out)/\(name)") as CFURL, type.identifier as CFString, 1, nil)!
  var props: [CFString: Any] = [:]
  if exif {
    props[kCGImagePropertyTIFFDictionary] = [
      kCGImagePropertyTIFFMake: "Canon", kCGImagePropertyTIFFModel: "Canon EOS R6",
    ]
    props[kCGImagePropertyExifDictionary] = [
      kCGImagePropertyExifDateTimeOriginal: "2023:05:01 14:30:15"
    ]
  }
  if let (lat, latRef, lon, lonRef) = gps {
    props[kCGImagePropertyGPSDictionary] = [
      kCGImagePropertyGPSLatitude: lat, kCGImagePropertyGPSLatitudeRef: latRef,
      kCGImagePropertyGPSLongitude: lon, kCGImagePropertyGPSLongitudeRef: lonRef,
    ]
  }
  CGImageDestinationAddImage(dest, image, props as CFDictionary)
  precondition(CGImageDestinationFinalize(dest), name)
}

save("exif.jpg", .jpeg, exif: true, gps: (37.5665, "N", 126.978, "E"))
save("exif.heic", .heic, exif: true, gps: (37.7749, "N", 122.4194, "W"))
save("plain.png", .png, exif: false)

// 화질만 다른 같은 장면 (거의 동일 탐지 테스트용)
let sw = 320, sh = 240
var scene = [UInt8](repeating: 0, count: sw * sh * 4)
var seed: UInt64 = 1
func rand(_ n: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int(seed >> 33) % n }
let rects = (0..<12).map { _ in (rand(sw), rand(sh), 20 + rand(sw / 3), 20 + rand(sh / 3), rand(256), rand(256), rand(256)) }
for y in 0..<sh { for x in 0..<sw {
  var (r, g, b) = (x * 255 / sw, y * 255 / sh, 128)
  for (rx, ry, rw, rh, cr, cg, cb) in rects where x >= rx && x < rx + rw && y >= ry && y < ry + rh { (r, g, b) = (cr, cg, cb) }
  let i = (y * sw + x) * 4
  scene[i] = UInt8(r); scene[i + 1] = UInt8(g); scene[i + 2] = UInt8(b); scene[i + 3] = 255
} }
let sceneCtx = CGContext(
  data: &scene, width: sw, height: sh, bitsPerComponent: 8, bytesPerRow: sw * 4,
  space: CGColorSpace(name: CGColorSpace.sRGB)!,
  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
for q in [90, 40] {
  let dest = CGImageDestinationCreateWithURL(
    URL(fileURLWithPath: "\(out)/scene_q\(q).jpg") as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
  CGImageDestinationAddImage(dest, sceneCtx.makeImage()!, [kCGImageDestinationLossyCompressionQuality: Double(q) / 100] as CFDictionary)
  precondition(CGImageDestinationFinalize(dest))
}
