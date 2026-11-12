import Foundation

/// Finds bundled resources both inside the hand-built .app and under `swift test`.
///
/// SwiftPM's generated `Bundle.module` accessor does not look in `Contents/Resources`
/// of a hand-assembled app bundle, so we check there first.
public enum ResourceLocator {
    public static func url(_ name: String, ext: String) -> URL? {
        if let resourceURL = Bundle.main.resourceURL,
           let bundle = Bundle(url: resourceURL.appendingPathComponent("PickerCore_PickerCore.bundle")),
           let url = bundle.url(forResource: name, withExtension: ext) {
            return url
        }
        return Bundle.module.url(forResource: name, withExtension: ext)
    }
}
