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

func save(_ name: String, _ type: UTType, exif: Bool) {
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
  CGImageDestinationAddImage(dest, image, props as CFDictionary)
  precondition(CGImageDestinationFinalize(dest), name)
}

save("exif.jpg", .jpeg, exif: true)
save("exif.heic", .heic, exif: true)
save("plain.png", .png, exif: false)
