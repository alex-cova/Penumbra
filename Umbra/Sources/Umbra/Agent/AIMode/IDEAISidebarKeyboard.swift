import Foundation

/// Painted order of AI mode's session list: open chats, then saved rows, per group.
enum IDEAISidebarKeyboard {
    enum Row: Hashable {
        case open(UUID)
        case saved(UUID)
    }

    static func chatOrder(openIDs: [UUID], savedIDs: [UUID]) -> [Row] {
        openIDs.map { .open($0) } + savedIDs.map { .saved($0) }
    }

    static func codeOrder(groups: [(openIDs: [UUID], savedIDs: [UUID])]) -> [Row] {
        groups.flatMap { chatOrder(openIDs: $0.openIDs, savedIDs: $0.savedIDs) }
    }
}
