import Foundation

struct IDEDockerImage: Decodable, Identifiable {
    let imageID: String
    let repository: String
    let tag: String
    let size: String

    var id: String { "\(imageID) \(repository) \(tag)" }

    private enum CodingKeys: String, CodingKey {
        case imageID = "ID"
        case repository = "Repository"
        case tag = "Tag"
        case size = "Size"
    }
}
