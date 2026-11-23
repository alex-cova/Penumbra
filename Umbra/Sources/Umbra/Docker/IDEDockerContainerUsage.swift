import Foundation

struct IDEDockerContainerUsage: Decodable {
    let id: String
    let cpu: String
    let memory: String

    var memoryUsed: String {
        memory.split(separator: "/", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespaces) ?? memory
    }

    private enum CodingKeys: String, CodingKey {
        case id = "ID"
        case cpu = "CPUPerc"
        case memory = "MemUsage"
    }
}
