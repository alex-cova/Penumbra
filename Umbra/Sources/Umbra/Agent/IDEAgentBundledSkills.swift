import Foundation

/// Skills that ship with Umbra, seeded into the app-support `skills` folder the command catalog
/// reads. Seeding copies a skill only when it is missing, so a user's own edits to it win.
enum IDEAgentBundledSkills {
    /// The skill folders in the bundle, by name.
    static let skills = ["pr"]

    private static func bundledDirectory() -> URL? {
        var bundles = [Bundle.main]
        #if SWIFT_PACKAGE
        bundles.append(Bundle.module)
        #endif
        for bundle in bundles {
            if let url = bundle.url(forResource: "Skills", withExtension: nil) { return url }
        }
        return nil
    }

    /// Copies each bundled skill into `appSupport/skills` when it is not already there.
    static func seed(appSupport: URL?) {
        seed(appSupport: appSupport, bundled: bundledDirectory())
    }

    static func seed(appSupport: URL?, bundled: URL?) {
        guard let appSupport, let bundled else { return }
        let folder = appSupport.appendingPathComponent("skills", isDirectory: true)
        for skill in skills {
            let source = bundled.appendingPathComponent(skill).appendingPathComponent("SKILL.md")
            let target = folder.appendingPathComponent(skill).appendingPathComponent("SKILL.md")
            guard !FileManager.default.fileExists(atPath: target.path),
                  let contents = try? Data(contentsOf: source)
            else { continue }
            try? FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? contents.write(to: target, options: .atomic)
        }
    }
}
