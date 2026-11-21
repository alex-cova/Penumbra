enum IDEDockerComposeCommand: String, CaseIterable, Identifiable {
    case status = "Status"
    case up = "Up"
    case stop = "Stop"
    case restart = "Restart"

    var id: Self { self }

    var arguments: [String] {
        switch self {
        case .status: ["ps", "--all"]
        case .up: ["up", "--detach"]
        case .stop: ["stop"]
        case .restart: ["restart"]
        }
    }
}
