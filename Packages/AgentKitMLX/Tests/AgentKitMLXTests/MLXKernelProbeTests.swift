import Foundation
import MLX
import Testing
@testable import AgentKitMLX

/// Runs one real kernel with no guard, to see whether MLX itself finds its Metal library in this
/// process. Opt-in: if it does not, MLX throws a C++ exception and the process ends.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["AGENTKIT_MLX_KERNEL_PROBE"] != nil))
struct MLXKernelProbeTests {
    @Test func aKernelRunsAndTheGuardAgreesWithMLX() {
        let guardSays = MLXMetalLibrary.install(extraRoots: MLXTestEnvironment.resourceRoots())
        let result = (MLXArray([1, 2, 3]) * 2).asArray(Int.self)
        #expect(result == [2, 4, 6])
        // MLX found its library, so a guard that says "missing" here would be a false alarm.
        #expect(guardSays != nil, "MLX ran, but the guard says the library is missing: \(MLXMetalLibrary.candidates(executableDirectory: Bundle.main.executableURL!.deletingLastPathComponent(), bundleRoots: [Bundle.main.bundleURL] + Bundle.allBundles.compactMap(\.resourceURL)).map(\.path))")
    }
}
