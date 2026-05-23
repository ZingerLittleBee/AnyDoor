import Foundation

extension Bundle {
    /// `CFBundleShortVersionString`, e.g. `"1.2.0"`.
    var shortVersionString: String? {
        infoDictionary?["CFBundleShortVersionString"] as? String
    }
}
