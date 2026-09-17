import Foundation
@preconcurrency import AppKit

@MainActor
protocol ReusableView {
    func prepareForReuse()
}

extension ReusableView {
    func prepareForReuse() {}
}

@MainActor
final class ViewReuseQueue<Key: Hashable, View: UIView & ReusableView> {
    private(set) var visibleViews: [Key: View] = [:]

    private var queuedViews: Set<View> = []

    init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(clearMemory),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func enqueueViews(withKeys keys: Set<Key>) {
        // Snapshot the visible count *before* removing anything in this batch. Using the live
        // (shrinking) `visibleViews.count` as the cap basis meant a single layout pass that
        // dequeues many views at once (e.g. a large/fast scroll) would starve the pool partway
        // through the batch and start deallocating views instead of reusing them.
        let usedViewCount = visibleViews.count
        for key in keys {
            if let view = visibleViews.removeValue(forKey: key) {
                view.prepareForReuse()
                view.removeFromSuperview()
                queueViewIfNeeded(view, usedViewCount: usedViewCount)
            }
        }
    }

    func dequeueView(forKey key: Key) -> View {
        if let view = visibleViews[key] {
            return view
        } else if !queuedViews.isEmpty {
            let view = queuedViews.removeFirst()
            visibleViews[key] = view
            return view
        } else {
            let view = View()
            visibleViews[key] = view
            return view
        }
    }

    private func queueViewIfNeeded(_ view: View, usedViewCount: Int) {
        // There's no need to let the queue grow large but deciding on a good number of views to allow in the queue is difficult.
        // We cap it at the number of views that were in use just before this batch of removals: there'll rarely be any need
        // for the queue to grow larger than that, but it also won't be starved mid-batch the way a shrinking live count would.
        if queuedViews.count < usedViewCount {
            queuedViews.insert(view)
        }
    }

    @objc private func clearMemory() {
        queuedViews.removeAll()
    }
}
