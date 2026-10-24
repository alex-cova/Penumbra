import Foundation
import FoundationModels

public enum AppleModelKind: String, Sendable, Hashable, CaseIterable {
    /// `SystemLanguageModel.default`: runs on this Mac, nothing is sent anywhere.
    case onDevice
    /// Apple's larger model on Private Cloud Compute (macOS 27).
    case privateCloudCompute
}

public enum AppleModelStatus: Sendable, Equatable {
    case available
    case deviceNotEligible
    case appleIntelligenceNotEnabled
    case modelNotReady
    /// Private Cloud Compute needs macOS 27.
    case requiresNewerOS
    case unavailable(String)
}

/// Whether Apple's models can be used right now, and the window each one has. Mirrors `MLXAvailability`.
public enum AppleModelAvailability {
    public static func status(for kind: AppleModelKind) -> AppleModelStatus {
        switch kind {
        case .onDevice:
            switch SystemLanguageModel.default.availability {
            case .available: return .available
            case .unavailable(.deviceNotEligible): return .deviceNotEligible
            case .unavailable(.appleIntelligenceNotEnabled): return .appleIntelligenceNotEnabled
            case .unavailable(.modelNotReady): return .modelNotReady
            case .unavailable: return .unavailable("Apple Intelligence is not available.")
            }
        case .privateCloudCompute:
            guard #available(macOS 27, *) else { return .requiresNewerOS }
            switch PrivateCloudComputeLanguageModel().availability {
            case .available: return .available
            case .unavailable(.deviceNotEligible): return .deviceNotEligible
            case .unavailable(.systemNotReady): return .modelNotReady
            case .unavailable: return .unavailable("Private Cloud Compute is not available.")
            }
        }
    }

    /// What to tell the user, or `nil` when the model can be used.
    public static func message(for status: AppleModelStatus, kind: AppleModelKind) -> String? {
        let name = kind == .onDevice ? "Apple Intelligence" : "Private Cloud Compute"
        switch status {
        case .available: return nil
        case .deviceNotEligible: return "This Mac doesn't support \(name)."
        case .appleIntelligenceNotEnabled:
            return "Turn on Apple Intelligence in System Settings ▸ Apple Intelligence & Siri."
        case .modelNotReady: return "\(name) is still getting its model ready. Try again in a few minutes."
        case .requiresNewerOS: return "\(name) needs macOS 27."
        case .unavailable(let reason): return reason
        }
    }

    public static func message(for kind: AppleModelKind) -> String? {
        message(for: status(for: kind), kind: kind)
    }

    /// The on-device model's window, or `nil` while it is unavailable. Cheap, so it can be read on the main actor.
    public static var onDeviceContextSize: Int? {
        SystemLanguageModel.default.isAvailable ? SystemLanguageModel.default.contextSize : nil
    }

    /// The model's window in tokens, or `nil` when it can't be read (model not available).
    public static func contextSize(for kind: AppleModelKind) async -> Int? {
        switch kind {
        case .onDevice:
            guard SystemLanguageModel.default.isAvailable else { return nil }
            return SystemLanguageModel.default.contextSize
        case .privateCloudCompute:
            guard #available(macOS 27, *) else { return nil }
            return try? await PrivateCloudComputeLanguageModel().contextSize
        }
    }

    /// Private Cloud Compute's quota, for settings: `nil` below macOS 27.
    public static func quotaDescription() -> String? {
        guard #available(macOS 27, *) else { return nil }
        let usage = PrivateCloudComputeLanguageModel().quotaUsage
        if usage.isLimitReached {
            if let reset = usage.resetDate {
                return "Quota reached. Resets \(reset.formatted(date: .abbreviated, time: .shortened))."
            }
            return "Quota reached."
        }
        if case .belowLimit(let below) = usage.status, below.isApproachingLimit { return "Approaching the quota." }
        return nil
    }
}
