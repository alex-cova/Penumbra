import Foundation
import LocalModelStore

/// The Precision and Parameters filters of "On-Device Models…". They narrow the suggestions and the
/// search results alike. Pure, so the matching is tested without a view.
struct IDELocalModelFilter: Equatable {
    /// How many bits a weight takes, from the `4-bit` tag the Hub puts on quantized repos.
    /// 1-bit is left out: MLX cannot run it, so it is refused before anything loads.
    enum Precision: Int, CaseIterable, Identifiable {
        case twoBit = 2, threeBit = 3, fourBit = 4, fiveBit = 5, sixBit = 6, eightBit = 8
        /// No bit tag: the weights are kept as published (16-bit) or use a mixed scheme.
        case full = 0

        var id: Int { rawValue }

        var bits: Int? { self == .full ? nil : rawValue }

        var title: String { bits.map { "\($0)-bit" } ?? "Full precision" }
    }

    /// The model's size in billions of parameters.
    enum Parameters: CaseIterable, Identifiable {
        case under2, from2to5, from5to10, from10to30, over30

        var id: Self { self }

        var title: String {
            switch self {
            case .under2: "Under 2B"
            case .from2to5: "2B – 5B"
            case .from5to10: "5B – 10B"
            case .from10to30: "10B – 30B"
            case .over30: "30B and over"
            }
        }

        func contains(_ billions: Double) -> Bool {
            switch self {
            case .under2: billions < 2
            case .from2to5: billions >= 2 && billions < 5
            case .from5to10: billions >= 5 && billions < 10
            case .from10to30: billions >= 10 && billions < 30
            case .over30: billions >= 30
            }
        }
    }

    var precision: Precision?
    var parameters: Parameters?

    var isActive: Bool { precision != nil || parameters != nil }

    /// A model whose precision or size is not known cannot be confirmed, so a filter on it hides the model.
    func matches(bits: Int?, billions: Double?) -> Bool {
        if let precision, precision.bits != bits { return false }
        if let parameters {
            guard let billions, parameters.contains(billions) else { return false }
        }
        return true
    }

    func matches(_ suggested: IDESuggestedLocalModel) -> Bool {
        matches(bits: suggested.bits, billions: suggested.parameterBillions)
    }

    func matches(_ result: HFModelSummary) -> Bool {
        matches(bits: Self.bits(of: result), billions: Self.billions(of: result))
    }

    // MARK: - Reading a repository

    /// From the Hub's tag (`4-bit`), else a `4bit` / `4-bit` suffix in the name.
    static func bits(of result: HFModelSummary) -> Int? {
        if let tag = result.quantization, let bits = leadingNumber(in: tag).map(Int.init) { return bits }
        return bits(inName: result.id)
    }

    static func bits(inName id: String) -> Int? {
        firstMatch(#"(?<![A-Za-z0-9])(\d{1,2})-?bit(?![A-Za-z])"#, in: LocalModelFormat.shortName(id)).flatMap { Int($0) }
    }

    /// The size in the name (`Qwen3-4B`, `SmolLM2-135M`, `Mixtral-8x7B`), which is the model's real size.
    /// The Hub's safetensors total counts packed words for a quantized model (a 27B model at 1 bit reports
    /// 1.7B), so it is used only for a model with no bit tag and no size in its name.
    static func billions(of result: HFModelSummary) -> Double? {
        if let named = billions(inName: result.id) { return named }
        guard bits(of: result) == nil, let count = result.parameterCount else { return nil }
        return Double(count) / 1_000_000_000
    }

    static func billions(inName id: String) -> Double? {
        let name = LocalModelFormat.shortName(id)
        let boundary = #"(?<![A-Za-z0-9.])"#
        if let experts = firstMatch(boundary + #"(\d+)x(\d+(?:\.\d+)?)[Bb](?![A-Za-z])"#, in: name, groups: 2),
            let count = Double(experts[0]), let each = Double(experts[1]) {
            return count * each
        }
        if let value = firstMatch(boundary + #"(\d+(?:\.\d+)?)[Bb](?![A-Za-z])"#, in: name).flatMap({ Double($0) }) {
            return value
        }
        if let value = firstMatch(boundary + #"(\d+(?:\.\d+)?)[Mm](?![A-Za-z])"#, in: name).flatMap({ Double($0) }) {
            return value / 1000
        }
        return nil
    }

    /// "27B", "1.7B" or "135M", for a row.
    static func sizeLabel(billions: Double) -> String {
        if billions < 1 { return String(format: "%.0fM", billions * 1000) }
        return billions == billions.rounded() ? String(format: "%.0fB", billions) : String(format: "%.1fB", billions)
    }

    private static func leadingNumber(in text: String) -> Double? {
        firstMatch(#"^(\d+)"#, in: text).flatMap { Double($0) }
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        firstMatch(pattern, in: text, groups: 1)?.first
    }

    private static func firstMatch(_ pattern: String, in text: String, groups: Int) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
            match.numberOfRanges > groups
        else { return nil }
        let found = (1...groups).compactMap { Range(match.range(at: $0), in: text).map { String(text[$0]) } }
        return found.count == groups ? found : nil
    }
}
