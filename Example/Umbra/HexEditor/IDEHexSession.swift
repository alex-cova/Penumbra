import AppKit
import Foundation
import HexKit
import Penumbra

enum HexPasteChoice: Sendable {
    case extend
    case truncate
    case cancel
}

enum IDEHexFindMode: String, Sendable {
    case hex
    case text
    case integer
}

/// One hex tab: the piece-table document, the caret, and the find/inspector state.
/// The workspace owns it. The view observes it and does not keep the workspace alive.
@MainActor
@Observable
final class IDEHexSession {
    let documentID: UUID
    private(set) var document: HexDocument
    let fileURL: URL?

    var selection: Range<Int64>
    var anchor: Int64
    var lowNibble = false
    var textPaneFocused = false
    var pendingHighNibble: UInt8?
    var insertMode = false
    var topRow: Int64 = 0
    var bytesPerRow: Int
    var groupSize: Int
    var uppercase: Bool
    var offsetBase: HexOffsetBase
    var colorByClass: Bool
    var encoding: HexPaneEncoding
    var readOnly: Bool
    var largeFileGated: Bool
    var openedBySniff: Bool
    var showSniffBanner: Bool
    var formatLabel: String?
    var bookmarks: HexBookmarks
    var inspectorVisible: Bool
    var littleEndianFirst: Bool
    var showsGoToOffset = false
    var findBarVisible = false
    var findText = ""
    var findMode: IDEHexFindMode = .hex
    var findEncoding: HexSearchTextEncoding = .utf8
    var findCaseInsensitive = false
    /// Width, in bytes, of an integer find. 1, 2, 4, or 8. Byte order is `littleEndianFirst`.
    var findIntegerWidth = 4
    var matches: [Range<Int64>] = []
    var matchIndex: Int?
    var matchCapped = false
    var findRunning = false
    var diskDifferences: [HexDiskDifference]?
    var showsDiskCompare = false
    var externalChange = false
    var saveMustOverwriteDisk = false
    var saveProgress: (written: Int64, total: Int64)?
    /// Runs on the save task after each chunk, before the writer continues.
    @ObservationIgnored var saveProgressHook: (@Sendable (Int64, Int64) -> Void)?
    /// Rows the canvas can draw. Navigation keeps the caret inside this window.
    /// Ignored by observation: the canvas writes it from layout, and a tracked write there loops SwiftUI.
    @ObservationIgnored private(set) var visibleRowCount: Int64 = 1
    @ObservationIgnored private var saveGeneration = 0
    /// When set, a paste that would grow the file in overwrite mode uses this instead of asking.
    var pasteChoiceForTest: HexPasteChoice?
    /// Bumps on every edit so a viewport cache cannot reuse a row whose bytes changed.
    var renderGeneration = 0

    var onChange: (() -> Void)?
    var onReloadFromDisk: (() -> Void)?
    var onOpenAsText: (() -> Void)?
    var onCompareWithDisk: (() -> Void)?
    var onMakeEditable: (() -> Void)?

    private var findTask: Task<Void, Never>?
    let writeCancellation = HexWriteCancellation()
    private var fixedBytesPerRow: Int?

    init(
        documentID: UUID,
        document: HexDocument,
        fileURL: URL?,
        settings: IDEHexSettings = .shared,
        openedBySniff: Bool = false,
        selection: Range<Int64> = 0..<0,
        topRow: Int64 = 0,
        bookmarks: [Int64] = []
    ) {
        self.documentID = documentID
        self.document = document
        self.fileURL = fileURL
        self.selection = selection
        self.anchor = selection.lowerBound
        self.bytesPerRow = 16
        self.groupSize = settings.groupSize
        self.uppercase = settings.uppercaseDigits
        self.offsetBase = settings.offsetBase
        self.colorByClass = settings.colorBytesByClass
        self.encoding = settings.textEncoding
        self.inspectorVisible = settings.inspectorVisible
        self.littleEndianFirst = settings.littleEndianFirst
        self.openedBySniff = openedBySniff
        let path = fileURL?.path ?? ""
        self.showSniffBanner = openedBySniff && !path.isEmpty && !settings.isSniffBannerDismissed(for: path)
        self.bookmarks = HexBookmarks(offsets: bookmarks)
        let gated = document.count > settings.largeFileEditThreshold
        self.largeFileGated = gated
        self.readOnly = gated
        if settings.bytesPerRowSetting == "auto" {
            fixedBytesPerRow = nil
            bytesPerRow = 16
        } else if let fixed = Int(settings.bytesPerRowSetting), [8, 16, 24, 32, 48, 64].contains(fixed) {
            fixedBytesPerRow = fixed
            bytesPerRow = fixed
        }
        if let url = fileURL {
            formatLabel = HexFormatDescriber.label(source: document.original)
            _ = url
        }
        clampViewport()
    }

    var caret: Int64 { selection.lowerBound }
    var isModified: Bool { document.isModified }
    var changedByteCount: Int64 { document.changedByteCount }
    var rowCount: Int64 { HexLayout.rowCount(byteCount: document.count, bytesPerRow: bytesPerRow) }

    var offsetStatus: String {
        let digits = HexLayout.offsetDigits(byteCount: document.count, base: .hexadecimal)
        let hex = HexLayout.formatOffset(caret, digits: digits, base: .hexadecimal, uppercase: uppercase)
        return "Offset 0x\(hex) (\(caret))"
    }

    var selectionStatus: String { "Sel \(max(0, selection.upperBound - selection.lowerBound)) B" }
    var modeStatus: String { insertMode ? "INS" : "OVR" }
    var paneStatus: String { textPaneFocused ? "Text" : "Hex" }
    var encodingStatus: String { encoding.displayName }

    var saveProgressText: String? {
        guard let saveProgress else { return nil }
        return "Saving \(saveProgress.written) / \(saveProgress.total)"
    }

    var accessibilitySummary: String {
        let byte = document.byte(at: caret).map { String(format: "0x%02X", $0) } ?? "none"
        var text = "\(offsetStatus), \(selectionStatus), byte \(byte), \(modeStatus), \(paneStatus) pane"
        if let saveProgressText { text += ", \(saveProgressText)" }
        return text
    }

    func noteVisibleRows(_ count: Int64) {
        let next = max(1, count)
        if next != visibleRowCount { visibleRowCount = next }
    }

    func metrics(charWidth: Double) -> HexRowMetrics {
        HexRowMetrics(
            bytesPerRow: bytesPerRow,
            groupSize: max(1, groupSize),
            charWidth: charWidth,
            offsetDigits: HexLayout.offsetDigits(byteCount: document.count, base: offsetBase)
        )
    }

    func setBytesPerRow(auto contentWidth: Double, charWidth: Double) {
        guard fixedBytesPerRow == nil else {
            bytesPerRow = fixedBytesPerRow ?? bytesPerRow
            return
        }
        let next = HexLayout.autoBytesPerRow(
            contentWidth: contentWidth,
            charWidth: charWidth,
            groupSize: groupSize,
            offsetDigits: HexLayout.offsetDigits(byteCount: document.count, base: offsetBase)
        )
        if next != bytesPerRow {
            bytesPerRow = next
            clampViewport()
        }
    }

    func useFixedBytesPerRow(_ value: Int?) {
        fixedBytesPerRow = value
        if let value { bytesPerRow = value }
        clampViewport()
        onChange?()
    }

    func dismissSniffBanner() {
        showSniffBanner = false
        if let path = fileURL?.path { IDEHexSettings.shared.dismissSniffBanner(for: path) }
        onChange?()
    }

    func makeEditable(confirmed: Bool) {
        guard confirmed else { return }
        readOnly = false
        largeFileGated = false
        onChange?()
    }

    // MARK: Selection

    func click(byte: Int64, pane: HexHit.Pane) {
        let index = clampIndex(byte)
        selection = index..<index
        anchor = index
        textPaneFocused = pane == .text
        if case .hex(let low) = pane { lowNibble = low } else { lowNibble = false }
        pendingHighNibble = nil
        reveal(index)
        onChange?()
    }

    /// Shift-click includes the byte under the pointer. The anchor stays the fixed edge.
    func shiftClick(byte: Int64) {
        let index = clampIndex(byte)
        if selection.isEmpty {
            selectBytes(from: anchor, through: index)
            return
        }
        let end: Int64
        if index < anchor {
            end = index
        } else if index < document.count {
            end = index + 1
        } else {
            end = document.count
        }
        selection = range(from: anchor, to: end)
        pendingHighNibble = nil
        reveal(index)
        onChange?()
    }

    /// Every byte from `originByte` through `focusByte`. A drag passes the mouse-down byte as the origin on each move.
    func selectBytes(from originByte: Int64, through focusByte: Int64) {
        let count = document.count
        let origin = min(max(0, originByte), count)
        let focus = min(max(0, focusByte), count)
        let lower = min(origin, focus)
        let higher = max(origin, focus)
        let upper = higher < count ? higher + 1 : count
        selection = lower..<upper
        anchor = focus >= origin ? lower : upper
        pendingHighNibble = nil
        reveal(focus)
        onChange?()
    }

    func selectAll() {
        selection = 0..<document.count
        anchor = 0
        pendingHighNibble = nil
        onChange?()
    }

    func selectGroup(at byte: Int64) {
        let size = Int64(max(1, groupSize))
        let start = (clampIndex(byte) / size) * size
        let end = min(document.count, start + size)
        selection = start..<end
        anchor = start
        pendingHighNibble = nil
        onChange?()
    }

    func move(by delta: Int64, extend: Bool) {
        let next: Int64
        if extend {
            next = clampIndex(movingEdge + delta)
            selection = range(from: anchor, to: next)
        } else {
            let base = selection.isEmpty ? caret : (delta < 0 ? selection.lowerBound : selection.upperBound)
            let step: Int64 = selection.isEmpty || delta.magnitude != 1 ? delta : 0
            next = clampIndex(base + step)
            selection = next..<next
            anchor = next
        }
        lowNibble = false
        pendingHighNibble = nil
        reveal(next)
        onChange?()
    }

    func moveByGroup(direction: Int, extend: Bool) {
        move(by: Int64(direction) * Int64(max(1, groupSize)), extend: extend)
    }

    func page(rows: Int64, extend: Bool) {
        move(by: rows * Int64(max(1, bytesPerRow)), extend: extend)
    }

    // MARK: Editing

    @discardableResult
    func typeNibble(_ nibble: UInt8) -> Bool {
        guard !readOnly, nibble < 16, !textPaneFocused else { return false }
        let at = caret
        if let high = pendingHighNibble {
            let byte = (high << 4) | nibble
            edit { $0.overwrite(at: at, bytes: [byte], coalescable: true) }
            pendingHighNibble = nil
            lowNibble = false
            let next = min(document.count, at + 1)
            selection = next..<next
            anchor = next
            onChange?()
            return true
        }
        if insertMode && selection.isEmpty {
            edit { $0.insert(at: at, bytes: [nibble << 4], coalescable: true) }
            selection = at..<at
            anchor = at
            pendingHighNibble = nibble
            lowNibble = true
            onChange?()
            return true
        }
        guard at < document.count else { return false }
        let existing = document.byte(at: at) ?? 0
        let byte = (nibble << 4) | (existing & 0x0F)
        edit { $0.overwrite(at: at, bytes: [byte], coalescable: true) }
        pendingHighNibble = nibble
        lowNibble = true
        selection = at..<at
        anchor = at
        onChange?()
        return true
    }

    @discardableResult
    func typeCharacter(_ character: Character) -> Bool {
        guard !readOnly, textPaneFocused else { return false }
        guard let byte = encoding.byte(for: character) else { return false }
        writeBytes([byte], coalescable: true)
        return true
    }

    func deleteBackward() {
        guard !readOnly else { return }
        if !insertMode {
            move(by: -1, extend: false)
            return
        }
        if !selection.isEmpty {
            edit { $0.delete(at: selection.lowerBound, count: selection.count) }
            let at = selection.lowerBound
            selection = at..<at
            anchor = at
            onChange?()
            return
        }
        guard caret > 0 else { return }
        let at = caret - 1
        edit { $0.delete(at: at, count: 1) }
        selection = at..<at
        anchor = at
        onChange?()
    }

    func deleteForward() {
        guard !readOnly, insertMode else { return }
        if !selection.isEmpty {
            deleteBackward()
            return
        }
        guard caret < document.count else { return }
        edit { $0.delete(at: caret, count: 1) }
        onChange?()
    }

    func fillSelection(with byte: UInt8) {
        guard !readOnly, !selection.isEmpty else { return }
        let range = selection
        edit { $0.fill(range, with: byte) }
        onChange?()
    }

    func zeroSelection() {
        fillSelection(with: 0)
    }

    @discardableResult
    func undo() -> Bool {
        guard !readOnly else { return false }
        var next = document
        guard next.undo() else { return false }
        document = next
        renderGeneration &+= 1
        clampViewport()
        cancelFind()
        onChange?()
        return true
    }

    @discardableResult
    func redo() -> Bool {
        guard !readOnly else { return false }
        var next = document
        guard next.redo() else { return false }
        document = next
        renderGeneration &+= 1
        clampViewport()
        cancelFind()
        onChange?()
        return true
    }

    func toggleInsertMode() {
        insertMode.toggle()
        pendingHighNibble = nil
        onChange?()
    }

    /// Shows or hides the data inspector and remembers the choice for the next launch.
    func setInspectorVisible(_ visible: Bool) {
        guard inspectorVisible != visible else { return }
        inspectorVisible = visible
        IDEHexSettings.shared.inspectorVisible = visible
        onChange?()
    }

    /// Hex and text panes. Tab in the grid calls this. A half-typed nibble is finished as it stands.
    func togglePane() {
        textPaneFocused.toggle()
        pendingHighNibble = nil
        lowNibble = false
        onChange?()
    }

    /// Writes an inspector value over the bytes at the caret. The caret stays put.
    @discardableResult
    func commitInspector(_ text: String, as spec: HexInspectorEdit) -> Bool {
        guard !readOnly, let bytes = HexInspector.encode(text, edit: spec) else { return false }
        let start = selection.lowerBound
        let end = start + Int64(bytes.count)
        guard start >= 0, end <= document.count else { return false }
        if document.bytes(in: start..<end) == bytes { return true }
        edit { $0.overwrite(at: start, bytes: bytes) }
        onChange?()
        return true
    }

    func toggleBookmark() {
        bookmarks.toggle(caret)
        onChange?()
    }

    @discardableResult
    func goTo(_ text: String) -> Bool {
        guard let offset = HexGoTo.resolve(text, caret: caret, count: document.count) else { return false }
        selection = offset..<offset
        anchor = offset
        pendingHighNibble = nil
        reveal(offset)
        showsGoToOffset = false
        onChange?()
        return true
    }

    func copy(style: HexCopyStyle? = nil) -> String {
        let range = selection.isEmpty ? caret..<min(document.count, caret + 1) : selection
        return HexCopy.format(document.bytes(in: range), style: style ?? IDEHexSettings.shared.copyStyle)
    }

    @discardableResult
    func paste(_ string: String) -> Bool {
        guard !readOnly else { return false }
        var bytes = HexCopy.parsePaste(string)
        guard !bytes.isEmpty else { return false }
        let start = selection.isEmpty ? caret : selection.lowerBound
        let replacing = selection.isEmpty ? (insertMode ? 0 : min(Int64(bytes.count), document.count - start)) : selection.count
        if !insertMode {
            let room = document.count - start
            if Int64(bytes.count) > room {
                let choice = pasteChoiceForTest ?? askPasteOverflow()
                switch choice {
                case .cancel: return false
                case .truncate: bytes = Array(bytes.prefix(Int(max(0, room))))
                case .extend: break
                }
                if bytes.isEmpty { return false }
            }
        }
        let remove = insertMode && selection.isEmpty ? 0 : min(replacing, document.count - start)
        edit { $0.replace(at: start, removing: max(0, remove), with: bytes) }
        let end = start + Int64(bytes.count)
        selection = end..<end
        anchor = end
        onChange?()
        return true
    }

    // MARK: Find

    func beginFind() {
        findBarVisible = true
        onChange?()
    }

    func updateFind() {
        findTask?.cancel()
        let text = findText
        let pattern: HexPattern?
        switch findMode {
        case .hex: pattern = HexPattern.hex(text)
        case .text: pattern = HexPattern.text(text, encoding: findEncoding, caseInsensitive: findCaseInsensitive)
        case .integer:
            pattern = HexPattern.integer(text, width: findIntegerWidth, littleEndian: littleEndianFirst)
        }
        guard let pattern, !pattern.isEmpty else {
            matches = []
            matchIndex = nil
            matchCapped = false
            findRunning = false
            onChange?()
            return
        }
        let snapshot = HexDocumentByteSource(document: document.snapshot())
        let origin = caret
        findRunning = true
        findTask = Task { [weak self] in
            let found: (matches: [Range<Int64>], capped: Bool)
            do {
                found = try await Task.detached {
                    try HexSearch.scan(in: snapshot, pattern: pattern, from: 0, limit: HexSearch.defaultLimit)
                }.value
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                self.matches = found.matches
                self.matchCapped = found.capped
                self.findRunning = false
                if let index = found.matches.firstIndex(where: { $0.lowerBound >= origin }) {
                    self.matchIndex = index
                    self.revealMatch(found.matches[index])
                } else if let first = found.matches.first {
                    self.matchIndex = 0
                    self.revealMatch(first)
                } else {
                    self.matchIndex = nil
                }
                self.onChange?()
            }
        }
    }

    func findNext() {
        guard !matches.isEmpty else { updateFind(); return }
        let index = matchIndex.map { ($0 + 1) % matches.count } ?? 0
        matchIndex = index
        revealMatch(matches[index])
        onChange?()
    }

    func findPrevious() {
        guard !matches.isEmpty else { return }
        let index = matchIndex.map { ($0 - 1 + matches.count) % matches.count } ?? (matches.count - 1)
        matchIndex = index
        revealMatch(matches[index])
        onChange?()
    }

    func replaceCurrent(with replacement: String) {
        guard !readOnly, let index = matchIndex, matches.indices.contains(index) else { return }
        let match = matches[index]
        let bytes: [UInt8]
        switch findMode {
        case .hex:
            guard let pattern = HexPattern.hex(replacement) else { return }
            bytes = pattern.bytes
        case .text:
            guard let pattern = HexPattern.text(replacement, encoding: findEncoding, caseInsensitive: false) else { return }
            bytes = pattern.bytes
        case .integer:
            guard let pattern = HexPattern.integer(replacement, width: findIntegerWidth, littleEndian: littleEndianFirst) else {
                return
            }
            bytes = pattern.bytes
        }
        edit { $0.replace(at: match.lowerBound, removing: match.count, with: bytes) }
        let end = match.lowerBound + Int64(bytes.count)
        selection = end..<end
        anchor = end
        updateFind()
    }

    func cancelFind() {
        findTask?.cancel()
        findTask = nil
        findRunning = false
        matches = []
        matchIndex = nil
    }

    func closeFindBar() {
        findBarVisible = false
        cancelFind()
        onChange?()
    }

    var matchStatus: String {
        if findRunning { return "Searching…" }
        guard let index = matchIndex, !matches.isEmpty else {
            return matches.isEmpty ? "No matches" : ""
        }
        let total = matchCapped ? "100,000+" : "\(matches.count)"
        return "\(index + 1) of \(total)"
    }

    // MARK: Disk

    func keepMine() {
        externalChange = false
        saveMustOverwriteDisk = true
        onChange?()
    }

    func refreshCleanKeepingViewport() throws {
        guard let file = document.original as? FileByteSource else { return }
        try file.reopen()
        let identity = fileURL.flatMap { try? HexFileIdentity.capture(url: $0) }
        document = HexDocument(source: file, identity: identity)
        externalChange = false
        renderGeneration &+= 1
        clampViewport()
        onChange?()
    }

    func compareWithDisk() async {
        guard let url = fileURL else { return }
        let snapshot = document.snapshot()
        let differences = try? await Task.detached {
            let disk = try FileByteSource(url: url)
            defer { disk.close() }
            return try HexDiskCompare.differingRanges(document: snapshot, disk: disk)
        }.value
        diskDifferences = differences ?? []
        showsDiskCompare = true
        onChange?()
    }

    func inspectorFields() -> [HexInspectorField] {
        let start = selection.lowerBound
        let available = max(0, document.count - start)
        let take = selection.isEmpty ? min(16, available) : min(8, selection.count, available)
        let bytes = document.bytes(in: start..<(start + take))
        return HexInspector.fields(bytes: bytes, littleEndianFirst: littleEndianFirst)
    }

    func selectionLengthText() -> (decimal: String, hex: String)? {
        let count = selection.count
        guard count > 8 else { return nil }
        return HexInspector.selectionLength(count)
    }

    func hashSelection() async -> (md5: String, sha1: String, sha256: String)? {
        guard selection.count > 8 else { return nil }
        let snapshot = document.snapshot()
        let range = selection
        let source = HexDocumentByteSource(document: snapshot)
        return try? await Task.detached {
            (
                try HexDigest.md5(source, range: range),
                try HexDigest.sha1(source, range: range),
                try HexDigest.sha256(source, range: range)
            )
        }.value
    }

    func rowBytes(_ row: Int64) -> [UInt8] {
        let width = Int64(max(1, bytesPerRow))
        let start = row * width
        guard start < document.count else { return [] }
        let end = min(document.count, start + width)
        return document.bytes(in: start..<end)
    }

    func publish(to workbench: WorkbenchDocument) {
        workbench.isDirty = document.isModified
        workbench.hexBookmarks = bookmarks.offsets
        let location = Int(clamping: caret)
        let length = Int(clamping: max(0, selection.upperBound - selection.lowerBound))
        workbench.selectedRange = NSRange(location: location, length: length)
        workbench.scrollOffset = CGPoint(x: 0, y: CGFloat(topRow))
    }

    func close() {
        findTask?.cancel()
        writeCancellation.cancel()
        if let file = document.original as? FileByteSource {
            file.close()
        }
    }

    func save(to url: URL, overwriteChanged: Bool = false) async throws {
        let snapshot = document.snapshot()
        let identity = document.identity
        let cancellation = writeCancellation
        let force = overwriteChanged || saveMustOverwriteDisk
        let hook = saveProgressHook
        saveGeneration &+= 1
        let generation = saveGeneration
        noteSaveProgress(written: 0, total: snapshot.count)
        do {
            try await Task.detached {
                try HexWriter.save(
                    snapshot,
                    to: url,
                    expected: identity,
                    overwriteChanged: force,
                    cancellation: cancellation,
                    progress: { written, total in
                        Task { @MainActor [weak self = self] in
                            guard let self, self.saveGeneration == generation else { return }
                            self.noteSaveProgress(written: written, total: total)
                        }
                        hook?(written, total)
                    }
                )
            }.value
        } catch {
            saveGeneration &+= 1
            saveProgress = nil
            onChange?()
            throw error
        }
        // Drop callbacks already queued for this save so a late chunk cannot revive the label.
        saveGeneration &+= 1
        saveProgress = nil
        let fresh = try? HexFileIdentity.capture(url: url)
        if document.sharesStorage(with: snapshot) {
            if let file = document.original as? FileByteSource, (try? file.reopen()) != nil {
                document = HexDocument(source: file, identity: fresh)
            } else {
                var next = document
                next.noteSaved(identity: fresh)
                document = next
            }
        } else if document.undoLogExtends(snapshot),
                  let file = document.original as? FileByteSource,
                  (try? file.reopen()) != nil {
            // The rename replaced the inode. Only steps appended after the snapshot are replayed.
            document = document.rebased(onto: file, identity: fresh, baseline: snapshot)
        } else {
            // The live log is not a prefix (the oldest step was dropped, undone, or coalesced).
            // Keep the piece table on the pre-rename descriptor. Reopening would point original
            // offsets at the flattened snapshot.
            var next = document
            next.noteFileIdentity(fresh)
            document = next
        }
        renderGeneration &+= 1
        saveMustOverwriteDisk = false
        externalChange = false
        clampViewport()
        onChange?()
    }

    // MARK: Private

    private func writeBytes(_ bytes: [UInt8], coalescable: Bool) {
        let start = selection.isEmpty ? caret : selection.lowerBound
        let removing: Int64
        if !selection.isEmpty {
            removing = selection.count
        } else if insertMode {
            removing = 0
        } else {
            removing = min(Int64(bytes.count), max(0, document.count - start))
        }
        edit { $0.replace(at: start, removing: removing, with: bytes, coalescable: coalescable) }
        let end = start + Int64(bytes.count)
        selection = end..<end
        anchor = end
        pendingHighNibble = nil
        onChange?()
    }

    private func edit(_ body: (inout HexDocument) -> Void) {
        guard !readOnly else { return }
        var next = document
        body(&next)
        document = next
        renderGeneration &+= 1
        clampViewport()
        cancelFind()
    }

    private func clampIndex(_ value: Int64) -> Int64 {
        min(max(0, value), document.count)
    }

    private func range(from anchor: Int64, to end: Int64) -> Range<Int64> {
        let lower = min(anchor, end)
        let upper = max(anchor, end)
        return clampIndex(lower)..<clampIndex(upper)
    }

    /// Exclusive offset that shift-arrows move. The anchor stays put, including when it is the right edge.
    private var movingEdge: Int64 {
        if anchor <= selection.lowerBound {
            return selection.upperBound
        }
        return selection.lowerBound
    }

    private func clampViewport() {
        let count = document.count
        if selection.lowerBound > count || selection.upperBound > count {
            let lower = min(selection.lowerBound, count)
            let upper = min(selection.upperBound, count)
            selection = lower..<upper
            anchor = min(anchor, count)
        }
        let rows = rowCount
        if topRow < 0 { topRow = 0 }
        if rows == 0 {
            topRow = 0
        } else if topRow >= rows {
            topRow = rows - 1
        }
    }

    private func noteSaveProgress(written: Int64, total: Int64) {
        saveProgress = (written, total)
        onChange?()
    }

    private func reveal(_ offset: Int64) {
        let width = Int64(max(1, bytesPerRow))
        let row = offset / width
        let window = max(1, visibleRowCount)
        if row < topRow { topRow = row }
        if row >= topRow + window { topRow = row - window + 1 }
        if topRow < 0 { topRow = 0 }
    }

    func revealCaret(visibleRows: Int64) {
        noteVisibleRows(visibleRows)
        reveal(caret)
    }

    private func revealMatch(_ range: Range<Int64>) {
        selection = range
        anchor = range.lowerBound
        reveal(range.lowerBound)
    }

    private func askPasteOverflow() -> HexPasteChoice {
        let alert = NSAlert()
        alert.messageText = "Paste extends past the end of the file"
        alert.informativeText = "Overwrite mode can extend the file, keep only the bytes that fit, or cancel."
        alert.addButton(withTitle: "Extend")
        alert.addButton(withTitle: "Truncate")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .extend
        case .alertSecondButtonReturn: return .truncate
        default: return .cancel
        }
    }
}

private extension Range where Bound == Int64 {
    var count: Int64 { Swift.max(0, upperBound - lowerBound) }
}

/// A snapshot of a hex document as a byte source, so a hash can run off the main actor.
struct HexDocumentByteSource: HexByteSource, Sendable {
    let document: HexDocument
    var count: Int64 { document.count }
    func read(_ range: Range<Int64>, into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        document.read(range, into: buffer)
    }
}
