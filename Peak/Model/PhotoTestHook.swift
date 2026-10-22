#if DEBUG
import Foundation
import PeakCore

extension AppModel {
    /// For checking photo labeling without tapping through the app (simulator, desk):
    /// launched with PEAK_TEST_PHOTO set to an image file, it opens that photo as if picked
    /// from the library and, once it's labeled, writes both kinds of picture and what was
    /// found to the app's Documents folder. The camera isn't started.
    static var testPhoto: String? { ProcessInfo.processInfo.environment["PEAK_TEST_PHOTO"] }

    @MainActor func openTestPhotoIfAsked() {
        guard let path = Self.testPhoto else { return }
        let url = URL(fileURLWithPath: path)
        let photo = LabeledPhoto.importing({ try Data(contentsOf: url) }, model: self)
        self.photo = photo
        Task { @MainActor in
            while case .loading = photo.stage { try? await Task.sleep(for: .milliseconds(200)) }
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let name = url.deletingPathExtension().lastPathComponent
            var report = "\(name): stage \(photo.stage), fit \(photo.fit)"
            if let a = photo.camera?.attitude {
                report += String(format: ", heading %.2f° pitch %.2f° roll %.2f°, fov %.2f°", a.heading, a.pitch, a.roll,
                                 photo.camera!.intrinsics.horizontalFOV)
            }
            for variant in PhotoOverlay.Variant.allCases {
                guard let overlay = photo.overlay(units: settings.units, ridges: settings.showRidges,
                                                  maxLabels: settings.labels.maxLabels, variant: variant),
                      let data = await photo.jpeg(overlay) else { continue }
                try? data.write(to: docs.appendingPathComponent("\(name)-\(variant.rawValue).jpg"))
                if variant == .labels {
                    let names = overlay.labels().compactMap { photo.scene?.allPeaks[$0.id]?.peak.name }
                    report += "\nlabels: " + names.joined(separator: ", ")
                }
            }
            try? (report + "\n").write(to: docs.appendingPathComponent("\(name).txt"), atomically: true, encoding: .utf8)
            print("PEAK_TEST_PHOTO done: \(report)")
        }
    }
}
#endif
