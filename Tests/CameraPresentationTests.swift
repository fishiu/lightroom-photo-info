// SPDX-License-Identifier: GPL-3.0-only
import Foundation

private struct TestFailure: Error, CustomStringConvertible { let description: String }
private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw TestFailure(description: message) }
}

private func photo(_ camera: String, actual: Double?, equivalent: Double? = nil) -> PhotoMetadata {
    PhotoMetadata(filename: "fixture.RAW", camera: camera, lens: "未记录",
        focalLength: actual.map { "\($0) mm" } ?? "未记录", shutter: "1/250 s",
        aperture: "f/4", iso: "100", captureDate: "2026-01-01", assetID: "test",
        focalLengthMM: actual, equivalentFocalLengthMM: equivalent)
}

@main struct CameraPresentationTests {
    static func main() throws {
        let cases: [(String, Double, String, String)] = [
            ("SONY ILCE-7CM2", 40, "SONY a7C II", "≈40 mm 等效"),
            ("Fujifilm GFX100RF", 35, "GFX100RF", "≈28 mm 等效"),
            ("RICOH IMAGING COMPANY, LTD. RICOH GR IV", 18.3, "RICOH GR4", "≈28 mm 等效"),
            ("FUJIFILM X100VI", 23, "X100VI", "≈35 mm 等效")
        ]
        for (camera, actual, name, equivalent) in cases {
            let view = CameraPresentation(photo: photo(camera, actual: actual))
            try expect(view.cameraName == name, "Camera alias failed: \(camera)")
            try expect(view.focalLengthText(equivalent: true) == equivalent, "Known-camera conversion failed: \(camera)")
            try expect(view.equivalentIsEstimated, "Fallback must be marked estimated")
        }
        let recordedCrop = CameraPresentation(photo: photo("RICOH GR IV", actual: 18.3, equivalent: 50))
        try expect(recordedCrop.equivalentFocalLength == "50 mm 等效" && !recordedCrop.equivalentIsEstimated,
                   "Recorded crop equivalent must override nominal camera specification")
        try expect(recordedCrop.actualFocalLength == "18.3 mm", "Actual focal length must remain unchanged")
        let fullFrameCrop = CameraPresentation(photo: photo("SONY ILCE-7CM2", actual: 40, equivalent: 60))
        try expect(fullFrameCrop.equivalentFocalLength == "60 mm 等效", "Recorded Sony crop must win over full-frame fallback")
        let unknown = CameraPresentation(photo: photo("Unknown Camera", actual: 23))
        try expect(unknown.equivalentFocalLength == "等效未知", "Unknown cameras must not inherit APS-C assumptions")
        let unknownRecorded = CameraPresentation(photo: photo("Unknown Camera", actual: 23, equivalent: 35))
        try expect(unknownRecorded.equivalentFocalLength == "35 mm 等效", "Explicit EXIF does not need a known camera")
        let zero = CameraPresentation(photo: photo("RICOH GR IV", actual: 18.3, equivalent: 0))
        try expect(zero.equivalentFocalLength == "≈28 mm 等效", "Zero EXIF equivalent means unknown")
        let missing = CameraPresentation(photo: photo("RICOH GR IV", actual: nil))
        try expect(missing.actualFocalLength == "未记录" && missing.equivalentFocalLength == "等效未知", "Missing actual must not fabricate a focal value")
        let digital = CameraPresentation(photo: photo("RICOH GR DIGITAL IV", actual: 6))
        try expect(digital.cameraName == "RICOH GR DIGITAL IV" && digital.equivalentFocalLength == "等效未知", "Old GR DIGITAL IV is not GR4")
        print("PASS: four camera aliases; nominal equivalents; recorded EXIF/crops win; unknown and missing values stay explicit")
    }
}
