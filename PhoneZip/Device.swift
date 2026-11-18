import Foundation

/// What to call this device in on-screen text: "iPhone", "iPad" or "Mac".
/// Read from the hardware model rather than UIDevice, so it can be used
/// off the main thread (export errors and skip reasons are built there).
enum Device {
    static let name: String = {
        let info = ProcessInfo.processInfo
        if info.isMacCatalystApp || info.isiOSAppOnMac { return "Mac" }
        let model = info.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? hardwareModel()
        if model.hasPrefix("iPad") { return "iPad" }
        if model.hasPrefix("iPod") { return "iPod touch" }
        return "iPhone"
    }()

    /// The machine identifier, such as "iPhone17,1" or "iPad16,3".
    private static func hardwareModel() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}
