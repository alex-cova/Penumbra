import Foundation
import JavaIntelligence
import SwiftIntelligence

extension JavaInspectionProfile {
    static let swiftSectionKey = "swift"

    /// The Swift choices of this profile: the `swift` section of its file. Standard when it has none, and setting the
    /// standard profile removes the section, so a profile that never touched Swift stays a Java-only file.
    var swift: SwiftInspectionProfile {
        get { SwiftInspectionProfile(sectionData: sections[Self.swiftSectionKey]) ?? .standard }
        set { sections[Self.swiftSectionKey] = newValue == .standard ? nil : newValue.sectionData }
    }
}

/// What the Swift inspections read to know which rules run on which file: the active profile's Swift choices and the
/// project folder, behind a lock so the editor's analysis (off the main actor) and the window (on it) can both use it.
final class IDESwiftInspectionResolver: @unchecked Sendable {
    private let lock = NSLock()
    private var profile = SwiftInspectionProfile.standard
    private var classifier = SwiftInspectionFileClassifier()

    /// The options for the file at `url` (the base choices for text with no file).
    func options(for url: URL?) -> SwiftInspectionOptions {
        let (profile, classifier) = lock.withLock { (self.profile, self.classifier) }
        return profile.options(for: url.map(classifier.context(for:)))
    }

    var currentProfile: SwiftInspectionProfile { lock.withLock { profile } }

    /// Takes the window's active profile; true when it differs from what was held.
    @discardableResult
    func update(profile: SwiftInspectionProfile, root: URL?) -> Bool {
        lock.withLock {
            let classifier = SwiftInspectionFileClassifier(projectRoot: root)
            guard profile != self.profile || classifier != self.classifier else { return false }
            self.profile = profile
            self.classifier = classifier
            return true
        }
    }
}
