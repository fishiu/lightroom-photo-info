// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Keeps camera labels compact and distinguishes recorded equivalents from camera-specific estimates.
struct CameraPresentation {
    let cameraName: String
    let actualFocalLength: String
    let equivalentFocalLength: String
    let equivalentIsEstimated: Bool
    private let actualTooltip: String
    private let equivalentTooltip: String

    init(photo: PhotoMetadata) {
        let model = KnownCamera.identify(photo.camera)
        cameraName = model?.displayName ?? photo.camera
        let actual = Self.positive(photo.focalLengthMM) ?? Self.legacyMillimeters(photo.focalLength)
        actualFocalLength = actual.map { Self.format($0) + " mm" } ?? "未记录"
        actualTooltip = "镜头实际焦距：\(actualFocalLength)。点击切换为 35mm 全画幅等效焦距。"

        if let recorded = Self.positive(photo.equivalentFocalLengthMM) {
            equivalentFocalLength = Self.format(recorded) + " mm 等效"
            equivalentIsEstimated = false
            equivalentTooltip = "35mm 全画幅等效焦距，来自照片 EXIF：\(Self.format(recorded)) mm。实际焦距：\(actualFocalLength)。不叠加 Lightroom 后期裁切。点击切换实际焦距。"
        } else if let model, let actual {
            let estimated = (actual * model.nominalEquivalentRatio).rounded()
            equivalentFocalLength = "≈" + Self.format(estimated) + " mm 等效"
            equivalentIsEstimated = true
            equivalentTooltip = "照片未记录 35mm 等效焦距，按 \(cameraName) 的官方规格估算。实际焦距：\(actualFocalLength)。未计入未记录的机内裁切、转接附件或 Lightroom 后期裁切。点击切换实际焦距。"
        } else {
            equivalentFocalLength = "等效未知"
            equivalentIsEstimated = false
            equivalentTooltip = "照片未记录 35mm 等效焦距，且没有可用于可靠换算的机型或实际焦距。实际焦距：\(actualFocalLength)。点击切换实际焦距。"
        }
    }

    func focalLengthText(equivalent: Bool) -> String {
        equivalent ? equivalentFocalLength : actualFocalLength
    }

    func focalLengthTooltip(equivalent: Bool) -> String {
        equivalent ? equivalentTooltip : actualTooltip
    }

    private static func positive(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }

    private static func legacyMillimeters(_ value: String) -> Double? {
        guard value.hasSuffix(" mm") else { return nil }
        return positive(Double(value.dropLast(3)))
    }

    private static func format(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        formatter.usesGroupingSeparator = false
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    private enum KnownCamera {
        case sonyA7CII, gfx100rf, ricohGR4, x100vi

        static func identify(_ raw: String) -> KnownCamera? {
            let name = raw.uppercased().replacingOccurrences(of: "Α", with: "A")
                .filter { $0.isLetter || $0.isNumber }
            if name.hasSuffix("ILCE7CM2") || name.hasSuffix("A7CII") || name.hasSuffix("A7C2") { return .sonyA7CII }
            if name.hasSuffix("GFX100RF") { return .gfx100rf }
            if name.hasSuffix("GRIV") || name.hasSuffix("GR4") { return .ricohGR4 }
            if name.hasSuffix("X100VI") { return .x100vi }
            return nil
        }

        var displayName: String {
            switch self {
            case .sonyA7CII: return "SONY a7C II"
            case .gfx100rf: return "GFX100RF"
            case .ricohGR4: return "RICOH GR4"
            case .x100vi: return "X100VI"
            }
        }

        var nominalEquivalentRatio: Double {
            switch self {
            // Full-frame normal still-image coverage. EXIF takes precedence for recorded APS-C crops.
            // https://helpguide.sony.net/ilc/2360/v1/en/contents/231h_specifications_ilc2360.html
            case .sonyA7CII: return 1
            // Official fixed-lens pairs avoid the incorrect generic APS-C 1.5x => 27mm result for GR IV.
            // https://www.fujifilm-x.com/en-us/products/cameras/gfx100rf/specifications/
            case .gfx100rf: return 28 / 35
            // https://www.ricoh-imaging.co.jp/japan/products/gr-4/spec/
            case .ricohGR4: return 28 / 18.3
            // https://www.fujifilm-x.com/en-us/products/cameras/x100vi/specifications/
            case .x100vi: return 35 / 23
            }
        }
    }
}
