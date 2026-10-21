import CryptoKit
import Foundation
import JavaIntelligence

/// A bookmark on a line of a file (1-based, matching the editor gutter).
struct IDEBookmark: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    /// The standardized absolute path of the file.
    var filePath: String
    var line: Int
    /// `0`–`9` or `A`–`Z` (one character), or nil for an anonymous bookmark.
    var mnemonic: String?
    var note: String
    var listID: UUID

    init(id: UUID = UUID(), filePath: String, line: Int, mnemonic: String? = nil, note: String = "", listID: UUID) {
        self.id = id
        self.filePath = filePath
        self.line = line
        self.mnemonic = mnemonic
        self.note = note
        self.listID = listID
    }

    var fileName: String { (filePath as NSString).lastPathComponent }
    var title: String { note.isEmpty ? "\(fileName):\(line)" : note }
    var url: URL { URL(fileURLWithPath: filePath) }
}

/// A named group of bookmarks (IntelliJ's bookmark lists).
struct IDEBookmarkList: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var name: String

    init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
    }
}

/// Which characters can name a bookmark.
enum IDEBookmarkMnemonic {
    static let characters: [Character] = Array("1234567890ABCDEFGHIJKLMNOPQRSTUVWXYZ")

    /// The mnemonic for a typed character: letters upper-cased; nil when it is not a digit or letter.
    static func normalized(_ character: Character) -> String? {
        let upper = Character(String(character).uppercased())
        return characters.contains(upper) ? String(upper) : nil
    }
}

/// Persists bookmarks and bookmark lists per project root, in one file shared by every window of
/// the app. Each public call reloads the file when it changed on disk first, so a second window's
/// store (or another process) is never overwritten.
final class IDEBookmarkStore: @unchecked Sendable {
    struct Snapshot: Codable, Equatable, Sendable {
        var lists: [IDEBookmarkList] = []
        var defaultListID: UUID?
        var bookmarks: [IDEBookmark] = []

        init() {}

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            lists = try container.decodeIfPresent([IDEBookmarkList].self, forKey: .lists) ?? []
            defaultListID = try container.decodeIfPresent(UUID.self, forKey: .defaultListID)
            bookmarks = try container.decodeIfPresent([IDEBookmark].self, forKey: .bookmarks) ?? []
        }

        /// A project always has a list to put a bookmark in; the first is the default. `id` is
        /// stable for the project (see ``IDEBookmarkStore/defaultListID(forKey:)``), so reading a
        /// project that has not stored anything yet names the same list every time.
        mutating func ensureDefaultList(named name: String, id: UUID) {
            if lists.isEmpty { lists.append(IDEBookmarkList(id: id, name: name)) }
            if defaultListID == nil || !lists.contains(where: { $0.id == defaultListID }) {
                defaultListID = lists[0].id
            }
        }
    }

    private let storeURL: URL
    private let lock = NSLock()
    private var projects: [String: Snapshot]
    private var stamp: FileChangeStamp

    init(storeURL: URL) {
        self.storeURL = storeURL
        projects = Self.load(storeURL) ?? [:]
        stamp = FileChangeStamp(url: storeURL)
    }

    static var defaultStoreURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("com.umbra.editor", isDirectory: true)
            .appendingPathComponent("bookmarks.json")
    }

    // MARK: - Reading

    func snapshot(project root: URL?) -> Snapshot {
        read(root) { $0 }
    }

    func lists(project root: URL?) -> [IDEBookmarkList] {
        read(root) { $0.lists }
    }

    func defaultListID(project root: URL?) -> UUID? {
        read(root) { $0.defaultListID }
    }

    func bookmarks(project root: URL?) -> [IDEBookmark] {
        read(root) { $0.bookmarks }
    }

    func bookmarks(forFile url: URL, project root: URL?) -> [IDEBookmark] {
        let path = url.standardizedFileURL.path
        return bookmarks(project: root).filter { $0.filePath == path }
    }

    func bookmark(atLine line: Int, file url: URL, project root: URL?) -> IDEBookmark? {
        bookmarks(forFile: url, project: root).first { $0.line == line }
    }

    func bookmark(withMnemonic mnemonic: String, project root: URL?) -> IDEBookmark? {
        bookmarks(project: root).first { $0.mnemonic == mnemonic }
    }

    /// Every bookmark in the order Next and Previous walk them: by file path, then line.
    func ordered(project root: URL?) -> [IDEBookmark] {
        bookmarks(project: root).sorted { ($0.filePath, $0.line) < ($1.filePath, $1.line) }
    }

    /// The bookmark after (or before) a position, wrapping around; nil when there are none.
    func neighbour(of position: (filePath: String, line: Int), forward: Bool, project root: URL?) -> IDEBookmark? {
        Self.neighbour(in: ordered(project: root), of: position, forward: forward)
    }

    static func neighbour(in ordered: [IDEBookmark], of position: (filePath: String, line: Int), forward: Bool) -> IDEBookmark? {
        guard !ordered.isEmpty else { return nil }
        if forward {
            return ordered.first { ($0.filePath, $0.line) > (position.filePath, position.line) } ?? ordered[0]
        }
        return ordered.last { ($0.filePath, $0.line) < (position.filePath, position.line) } ?? ordered[ordered.count - 1]
    }

    // MARK: - Bookmarks

    /// Adds an anonymous bookmark on `line` (to the default list), or removes the one there.
    @discardableResult
    func toggle(atLine line: Int, file url: URL, project root: URL?) -> IDEBookmark? {
        let path = url.standardizedFileURL.path
        var added: IDEBookmark?
        mutate(root) { snapshot in
            if let index = snapshot.bookmarks.firstIndex(where: { $0.filePath == path && $0.line == line }) {
                snapshot.bookmarks.remove(at: index)
            } else if let listID = snapshot.defaultListID {
                let bookmark = IDEBookmark(filePath: path, line: line, listID: listID)
                snapshot.bookmarks.append(bookmark)
                added = bookmark
            }
        }
        return added
    }

    /// Gives the bookmark on `line` a mnemonic, adding the bookmark when the line has none. A
    /// mnemonic names one bookmark per project: another bookmark that has it loses it, and is
    /// returned so the caller can say so. Nil `mnemonic` makes the bookmark anonymous.
    @discardableResult
    func setMnemonic(_ mnemonic: String?, atLine line: Int, file url: URL, project root: URL?) -> IDEBookmark? {
        let path = url.standardizedFileURL.path
        var displaced: IDEBookmark?
        mutate(root) { snapshot in
            if let mnemonic, let owner = snapshot.bookmarks.firstIndex(where: {
                $0.mnemonic == mnemonic && !($0.filePath == path && $0.line == line)
            }) {
                snapshot.bookmarks[owner].mnemonic = nil
                displaced = snapshot.bookmarks[owner]
            }
            if let index = snapshot.bookmarks.firstIndex(where: { $0.filePath == path && $0.line == line }) {
                snapshot.bookmarks[index].mnemonic = mnemonic
            } else if let listID = snapshot.defaultListID {
                snapshot.bookmarks.append(IDEBookmark(filePath: path, line: line, mnemonic: mnemonic, listID: listID))
            }
        }
        return displaced
    }

    func setNote(_ note: String, bookmarkID: UUID, project root: URL?) {
        mutate(root) { snapshot in
            guard let index = snapshot.bookmarks.firstIndex(where: { $0.id == bookmarkID }) else { return }
            snapshot.bookmarks[index].note = note
        }
    }

    func remove(bookmarkID: UUID, project root: URL?) {
        mutate(root) { $0.bookmarks.removeAll { $0.id == bookmarkID } }
    }

    func move(bookmarkID: UUID, toList listID: UUID, project root: URL?) {
        mutate(root) { snapshot in
            guard snapshot.lists.contains(where: { $0.id == listID }),
                  let index = snapshot.bookmarks.firstIndex(where: { $0.id == bookmarkID }) else { return }
            snapshot.bookmarks[index].listID = listID
        }
    }

    /// Puts the file's bookmarks on the lines the editor moved them to (`lines` by id) and removes
    /// `removed` (their lines were deleted). Writes only when something changed.
    @discardableResult
    func moveLines(in url: URL, to lines: [UUID: Int], removing removed: Set<UUID>, project root: URL?) -> Bool {
        let path = url.standardizedFileURL.path
        var changed = false
        mutate(root, persistOnlyIf: { changed }) { snapshot in
            let before = snapshot.bookmarks.count
            snapshot.bookmarks.removeAll { removed.contains($0.id) }
            changed = snapshot.bookmarks.count != before
            for index in snapshot.bookmarks.indices where snapshot.bookmarks[index].filePath == path {
                if let line = lines[snapshot.bookmarks[index].id], line != snapshot.bookmarks[index].line {
                    snapshot.bookmarks[index].line = line
                    changed = true
                }
            }
        }
        return changed
    }

    // MARK: - Lists

    @discardableResult
    func createList(named name: String, project root: URL?) -> IDEBookmarkList {
        let list = IDEBookmarkList(name: name)
        mutate(root) { $0.lists.append(list) }
        return list
    }

    func renameList(_ listID: UUID, to name: String, project root: URL?) {
        mutate(root) { snapshot in
            guard let index = snapshot.lists.firstIndex(where: { $0.id == listID }) else { return }
            snapshot.lists[index].name = name
        }
    }

    func setDefaultList(_ listID: UUID, project root: URL?) {
        mutate(root) { snapshot in
            if snapshot.lists.contains(where: { $0.id == listID }) { snapshot.defaultListID = listID }
        }
    }

    /// Deleting a list deletes its bookmarks (IntelliJ). The last list stays: a project always has
    /// somewhere to put a bookmark.
    func deleteList(_ listID: UUID, project root: URL?) {
        mutate(root) { snapshot in
            guard snapshot.lists.count > 1 else { return }
            snapshot.lists.removeAll { $0.id == listID }
            snapshot.bookmarks.removeAll { $0.listID == listID }
        }
    }

    // MARK: - Storage

    private static func load(_ url: URL) -> [String: Snapshot]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([String: Snapshot].self, from: data)
    }

    /// A UUID made from the project key, so the implicit first list is the same value every time.
    static func defaultListID(forKey key: String) -> UUID {
        let digest = Array(SHA256.hash(data: Data(("umbra.bookmarks.default-list:" + key).utf8)))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    private func key(for root: URL?) -> String {
        root?.standardizedFileURL.path ?? ""
    }

    private func defaultListName(for root: URL?) -> String {
        let name = root?.standardizedFileURL.lastPathComponent ?? ""
        return name.isEmpty ? "Bookmarks" : name
    }

    /// Caller must hold `lock`.
    private func reloadIfChangedOnDisk() {
        guard stamp.hasChanged(at: storeURL) else { return }
        stamp.update(at: storeURL)
        if let loaded = Self.load(storeURL) { projects = loaded }
    }

    private func read<Result>(_ root: URL?, _ body: (Snapshot) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        reloadIfChangedOnDisk()
        var snapshot = projects[key(for: root)] ?? Snapshot()
        snapshot.ensureDefaultList(named: defaultListName(for: root), id: Self.defaultListID(forKey: key(for: root)))
        return body(snapshot)
    }

    private func mutate(_ root: URL?, persistOnlyIf shouldPersist: (() -> Bool)? = nil, _ change: (inout Snapshot) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        reloadIfChangedOnDisk()
        var snapshot = projects[key(for: root)] ?? Snapshot()
        snapshot.ensureDefaultList(named: defaultListName(for: root), id: Self.defaultListID(forKey: key(for: root)))
        change(&snapshot)
        if let shouldPersist, !shouldPersist() { return }
        projects[key(for: root)] = snapshot
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(projects) else { return }
        try? FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: storeURL, options: .atomic)
        stamp.update(at: storeURL)
    }
}
