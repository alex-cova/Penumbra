import Foundation

/// Pure tab-list index math shared by editor panes and host-app tab bars.
public enum TabListEngine {
    public static func canOpen(count: Int, max: Int) -> Bool {
        count < max
    }

    /// Index to select after closing tab at `closing` (count is tab count *before* removal).
    public static func selectionIndexAfterClose(closing: Int, selected: Int, count: Int) -> Int? {
        guard count > 1 else { return nil }
        if closing != selected {
            return selected > closing ? selected - 1 : selected
        }
        return closing < count - 1 ? closing : closing - 1
    }

    public static func nextIndex(after index: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        return (index + 1) % count
    }

    public static func previousIndex(before index: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        return (index - 1 + count) % count
    }

    public static func reorderDestination(from: Int, to: Int) -> Int {
        to > from ? to + 1 : to
    }

    public static func clamp(count: Int, selectedIndex: Int?, maxCount: Int) -> (count: Int, selectedIndex: Int?) {
        let capped = min(count, maxCount)
        guard capped > 0 else { return (0, nil) }
        let clampedSelection = selectedIndex.map { max(0, min($0, capped - 1)) } ?? 0
        return (capped, clampedSelection)
    }

    /// Disambiguates tab titles that share a display name (e.g. two open `index.ts` files in
    /// different folders) by appending the parent directory name, e.g. `"index.ts — utils"`.
    /// - Parameters:
    ///   - fileNames: display name for each open tab, in tab order.
    ///   - urls: backing file URL for each tab, `nil` for untitled buffers, same order/count as
    ///     `fileNames`.
    /// - Returns: one title per tab. A tab whose name is unique keeps it unchanged. Untitled
    ///   buffers (`nil` URL) never collide with anything since they have no path to disambiguate
    ///   with.
    public static func disambiguatedTitles(fileNames: [String], urls: [URL?]) -> [String] {
        guard fileNames.count == urls.count else { return fileNames }

        var countByName: [String: Int] = [:]
        for name in fileNames {
            countByName[name, default: 0] += 1
        }

        return zip(fileNames, urls).map { name, url in
            guard countByName[name, default: 0] > 1, let url else { return name }
            let parent = url.deletingLastPathComponent().lastPathComponent
            guard !parent.isEmpty else { return name }
            return "\(name) — \(parent)"
        }
    }
}
