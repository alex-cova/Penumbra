import Foundation

enum MetalActivation {
    static let defaultsKey = "PenumbraMetalRendering"

    /// Default value of `TextView.isMetalRenderingEnabled`: `true` in production, `false` under
    /// XCTest so the CG-path test suite keeps exercising the CG path. `MetalActivation.resolved`
    /// still requires a Metal device and honours the `PenumbraMetalRendering` kill switch, so a
    /// headless CI host without a GPU falls back to CG regardless.
    static var defaultPropertyValue: Bool {
        !isRunningUnderXCTest
    }

    static var isRunningUnderXCTest: Bool {
        let environment = ProcessInfo.processInfo.environment
        if environment["XCTestConfigurationFilePath"] != nil || environment["XCTestBundlePath"] != nil {
            return true
        }
        return NSClassFromString("XCTestCase") != nil
    }

    /// Single resolution function. Call from `TextView` init and on flag/defaults change.
    static func resolved(
        property: Bool,
        deviceAvailable: Bool,
        defaults: Bool?
    ) -> Bool {
        guard deviceAvailable else {
            return false
        }
        if defaults == false {
            return false
        }
        if property == false {
            return false
        }
        if defaults == true {
            return true
        }
        return property
    }
}
