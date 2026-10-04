import Foundation
import MLX

public enum MLXAvailabilityStatus: Equatable, Sendable {
    case available
    case notAppleSilicon
    /// The build has no compiled Metal kernels (`mlx.metallib` / `mlx-swift_Cmlx.bundle`). MLX would
    /// throw a C++ exception on first use, which ends the process, so it is checked first.
    case missingMetalLibrary
}

public enum MLXAvailability {
    /// Decided at compile time per architecture slice. MLX builds for x86_64 but cannot run there,
    /// so the Intel slice must never reach a model load. Running the app under Rosetta lands here too.
    public static func currentStatus(metalLibrary: URL? = MLXMetalLibrary.install(extraRoots: LocalModelRuntime.extraMetalSearchRoots)) -> MLXAvailabilityStatus {
        #if arch(arm64)
        metalLibrary == nil ? .missingMetalLibrary : .available
        #else
        .notAppleSilicon
        #endif
    }

    public static func title(for status: MLXAvailabilityStatus) -> String {
        switch status {
        case .available: "On-device models ready"
        case .notAppleSilicon: "Apple silicon required"
        case .missingMetalLibrary: "This build has no MLX shaders"
        }
    }

    public static func message(for status: MLXAvailabilityStatus) -> String {
        switch status {
        case .available:
            "Download a model from Hugging Face and run it entirely on this Mac."
        case .notAppleSilicon:
            "On-device models run on Apple’s MLX framework, which needs an M-series Mac. They are unavailable on Intel or under Rosetta."
        case .missingMetalLibrary:
            "MLX’s Metal kernels (mlx.metallib) were not found next to the app. Build with Scripts/build-app.sh, or run from the SwiftPM build folder."
        }
    }
}

/// Finds the compiled Metal kernels and tells MLX where they are.
///
/// MLX looks in a few places of its own (a colocated `mlx.metallib`, then `mlx-swift_Cmlx.bundle` under
/// the main bundle or a loaded bundle) and, finding none, throws a C++ exception that ends the
/// process. So the app looks first, in those places and in the app's `Resources`, and either points
/// MLX at the file (`GPU.metallib`) or reports that this build has none.
public enum MLXMetalLibrary {
    static let bundleName = "mlx-swift_Cmlx.bundle"

    /// MLX's own places, in its order, then plain `mlx.metallib` / `default.metallib` files in each root.
    public static func candidates(executableDirectory: URL, bundleRoots: [URL]) -> [URL] {
        var result = [
            executableDirectory.appendingPathComponent("mlx.metallib"),
            executableDirectory.appendingPathComponent("Resources/mlx.metallib"),
        ]
        for root in bundleRoots {
            let bundle = root.appendingPathComponent(bundleName)
            result.append(bundle.appendingPathComponent("Contents/Resources/default.metallib"))
            result.append(bundle.appendingPathComponent("default.metallib"))
        }
        for root in bundleRoots {
            result.append(root.appendingPathComponent("mlx.metallib"))
        }
        return result
    }

    public static func locate(
        executableDirectory: URL, bundleRoots: [URL], fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> URL? {
        candidates(executableDirectory: executableDirectory, bundleRoots: bundleRoots).first(where: fileExists)
    }

    /// Where the running process could have its library: the main bundle, its `Resources`, every
    /// loaded bundle's resources, and any `extraRoots` (a test host's resource folder).
    static func roots(extra: [URL] = []) -> [URL] {
        var roots = [Bundle.main.bundleURL]
        if let resources = Bundle.main.resourceURL { roots.append(resources) }
        roots += Bundle.allBundles.compactMap(\.resourceURL)
        return roots + extra
    }

    /// The library the running process can reach, without telling MLX anything.
    public static var current: URL? {
        guard let executable = Bundle.main.executableURL else { return nil }
        return locate(executableDirectory: executable.deletingLastPathComponent(), bundleRoots: roots())
    }

    /// Finds the library and points MLX at it. Call before the first MLX operation; safe to repeat.
    /// `nil` means MLX has nothing to load and must not be used.
    @discardableResult
    public static func install(extraRoots: [URL] = []) -> URL? {
        guard let executable = Bundle.main.executableURL,
              let found = locate(executableDirectory: executable.deletingLastPathComponent(), bundleRoots: roots(extra: extraRoots))
        else { return nil }
        #if arch(arm64)
        if GPU.metallib != found { GPU.metallib = found }
        #endif
        return found
    }
}
