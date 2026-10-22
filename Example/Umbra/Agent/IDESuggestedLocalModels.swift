import Foundation

/// A short, hand-picked list of on-device models for "On-Device Models…" and the setup sheet, so a first
/// download is one click instead of a Hugging Face search. All are quantized MLX conversions, mostly from
/// `mlx-community`. Sizes are approximate; the real size is read when a model is chosen from a search.
struct IDESuggestedLocalModel: Identifiable, Equatable, Sendable {
    enum Purpose: Equatable, Sendable {
        /// Chat and the agent: the chat template takes tools.
        case agent
        /// Fill-in-the-middle for Code Completion; not meant for chat.
        case completion
    }

    let id: String
    let blurb: String
    let approximateBytes: Int64
    /// Size in billions of parameters, and bits per weight, for the Parameters and Precision filters.
    let parameterBillions: Double
    let bits: Int
    let purpose: Purpose
    /// Memory the model is comfortable in, in GB; `nil` runs anywhere MLX does.
    let recommendedMemoryGB: Int?

    /// Whether this Mac has the memory the model is comfortable in.
    func fitsMemory(_ physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> Bool {
        guard let gigabytes = recommendedMemoryGB else { return true }
        return physicalMemory >= UInt64(gigabytes) * 1_000_000_000 * 9 / 10
    }
}

enum IDESuggestedLocalModels {
    /// The first one is what the setup sheet offers.
    static let all: [IDESuggestedLocalModel] = [
        IDESuggestedLocalModel(
            id: "mlx-community/Qwen3-4B-4bit", blurb: "Best starting point: chat and the agent, with tool use.",
            approximateBytes: 2_300_000_000, parameterBillions: 4, bits: 4, purpose: .agent, recommendedMemoryGB: 8),
        IDESuggestedLocalModel(
            id: "mlx-community/Qwen3-1.7B-4bit", blurb: "Small and fast, for a Mac with little memory.",
            approximateBytes: 1_000_000_000, parameterBillions: 1.7, bits: 4, purpose: .agent, recommendedMemoryGB: nil),
        IDESuggestedLocalModel(
            id: "mlx-community/Qwen3-8B-4bit", blurb: "Stronger answers and tool use; needs more memory.",
            approximateBytes: 4_700_000_000, parameterBillions: 8, bits: 4, purpose: .agent, recommendedMemoryGB: 16),
        IDESuggestedLocalModel(
            id: "mlx-community/Llama-3.2-3B-Instruct-4bit", blurb: "A general chat model from Meta.",
            approximateBytes: 1_800_000_000, parameterBillions: 3, bits: 4, purpose: .agent, recommendedMemoryGB: nil),
        IDESuggestedLocalModel(
            id: IDEInlineCompletionService.recommendedModelID, blurb: "For Code Completion as you type, not for chat.",
            approximateBytes: 900_000_000, parameterBillions: 1.5, bits: 4, purpose: .completion, recommendedMemoryGB: nil),
    ]

    /// What the setup sheet downloads in one click.
    static var recommendedForChat: IDESuggestedLocalModel { all[0] }
}
