// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import CoreGraphics

@main struct SidebarSelectionTests {
    static func image(bands: [Range<Int>], background: UInt8 = 44, selection: UInt8 = 32) -> CGImage {
        let width = 400, height = 600
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let shade = bands.contains { $0.contains(y) } ? selection : background
                let offset = (y * width + x) * 4
                pixels[offset] = shade; pixels[offset + 1] = shade; pixels[offset + 2] = shade
                pixels[offset + 3] = 255
            }
        }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: CGDataProvider(data: Data(pixels) as CFData)!, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent)!
    }

    static func main() {
        let row = AlbumTokenReader.selectedSidebarRow(in: image(bands: [160..<240]), pointHeight: 300)
        precondition(row == CGRect(x: 0, y: 160, width: 400, height: 80))
        for bands in [[], [160..<180], [0..<80], [160..<240, 320..<400], [550..<600]] {
            precondition(AlbumTokenReader.selectedSidebarRow(in: image(bands: bands), pointHeight: 300) == nil,
                         "Ordinary, thin, multiple, or clipped bands must not imply a selected album")
        }
        precondition(AlbumTokenReader.selectedSidebarRow(
            in: image(bands: [160..<240], background: 220, selection: 200), pointHeight: 300) == nil)
        print("PASS: only a complete unique selected sidebar row is recognized; unknown backgrounds fail closed")
    }
}
