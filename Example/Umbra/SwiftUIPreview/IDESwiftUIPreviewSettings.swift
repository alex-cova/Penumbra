import Foundation

/// What Settings ▸ SwiftUI Preview changes. UserDefaults reads are thread-safe, so the simulator
/// service (an actor) and the session (main actor) read the same keys.
enum IDESwiftUIPreviewSettings {
    static let idleMinutesKey = "umbra.swiftUIPreview.idleMinutes"
    static let startsSimulatorWithBuildKey = "umbra.swiftUIPreview.simulatorStartsWithBuild"
    static let offersPhonesKey = "umbra.swiftUIPreview.offersPhones"
    static let offersTabletsKey = "umbra.swiftUIPreview.offersTablets"
    static let lastBootSecondsKey = "umbra.swiftUIPreview.lastBootSeconds"

    static let defaultIdleMinutes = 10
    static let idleMinutesRange = 0...240

    /// Minutes without use before a preview's host stops and, ten minutes of the same again later, a
    /// device Umbra booted is shut down. 0 keeps them until the panel closes or Umbra quits.
    static var idleMinutes: Int {
        get {
            guard UserDefaults.standard.object(forKey: idleMinutesKey) != nil else { return defaultIdleMinutes }
            return min(max(UserDefaults.standard.integer(forKey: idleMinutesKey), idleMinutesRange.lowerBound), idleMinutesRange.upperBound)
        }
        set { UserDefaults.standard.set(newValue, forKey: idleMinutesKey) }
    }

    /// nil when idle stops are off.
    static var idleInterval: Duration? {
        let minutes = idleMinutes
        return minutes > 0 ? .seconds(minutes * 60) : nil
    }

    /// True (the default): the device boots while the project builds, which is faster. False: after
    /// the build, which keeps the two from competing for the CPU.
    static var startsSimulatorWithBuild: Bool {
        get { UserDefaults.standard.object(forKey: startsSimulatorWithBuildKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: startsSimulatorWithBuildKey) }
    }

    static var offersPhones: Bool {
        get { UserDefaults.standard.object(forKey: offersPhonesKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: offersPhonesKey) }
    }

    static var offersTablets: Bool {
        get { UserDefaults.standard.object(forKey: offersTabletsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: offersTabletsKey) }
    }

    /// Whether the Device menu lists a device of this `productFamily`. Phones are always offered
    /// when both are switched off: an empty menu would be no choice at all.
    static func offers(family: String) -> Bool {
        let phones = offersPhones || !offersTablets
        return family == "iPad" ? offersTablets : phones
    }

    /// How long the last cold start of a device took, in seconds: shown while the next one runs.
    static var lastBootSeconds: Double? {
        get {
            let value = UserDefaults.standard.double(forKey: lastBootSecondsKey)
            return value > 0 ? value : nil
        }
        set { UserDefaults.standard.set(newValue ?? 0, forKey: lastBootSecondsKey) }
    }
}
