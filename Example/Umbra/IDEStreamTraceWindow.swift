import AppKit
import JavaIntelligence
import SwiftUI

/// What the Stream Trace window shows: a chain being traced, its stages, or why it failed.
@MainActor
@Observable
final class IDEStreamTraceModel {
    enum Content {
        case loading
        case trace(stages: [[JavaStreamTraceElement]], result: JavaDebugValue?)
        case failure(String)
    }

    var chain: JavaStreamChain?
    var content: Content = .loading
    var isFlat = false
    /// The element picked, as (stage, index); its sources and results are highlighted.
    var selection: (stage: Int, index: Int)?
    var session: JavaDebugSession?

    /// For each stage after the first, the index of each element's source in the previous stage.
    func links(for stages: [[JavaStreamTraceElement]]) -> [[Int?]] {
        guard let chain, stages.count > 1 else { return [] }
        return (1..<stages.count).map { stage in
            let operation = stage - 1 < chain.intermediates.count ? chain.intermediates[stage - 1].name : ""
            return chain.links(from: stages[stage - 1], to: stages[stage], operation: operation)
        }
    }

    /// Every element linked to the selection, before and after it: (stage, index) pairs.
    func related(stages: [[JavaStreamTraceElement]], links: [[Int?]]) -> Set<[Int]> {
        guard let selection else { return [] }
        var result: Set<[Int]> = [[selection.stage, selection.index]]
        // Back to the source.
        var stage = selection.stage
        var index: Int? = selection.index
        while stage > 0, let current = index, stage - 1 < links.count, current < links[stage - 1].count {
            index = links[stage - 1][current]
            stage -= 1
            if let index { result.insert([stage, index]) }
        }
        // Forward to what it became.
        var frontier: Set<Int> = [selection.index]
        stage = selection.stage
        while stage < links.count, !frontier.isEmpty {
            var next: Set<Int> = []
            for (outputIndex, source) in links[stage].enumerated() where source.map(frontier.contains) == true {
                next.insert(outputIndex)
                result.insert([stage + 1, outputIndex])
            }
            frontier = next
            stage += 1
        }
        return result
    }
}

/// The Stream Trace window (Trace Current Stream Chain), one per workspace.
@MainActor
final class IDEStreamTraceWindowController {
    private let model = IDEStreamTraceModel()
    private var window: NSWindow?

    func showLoading(chain: JavaStreamChain) {
        model.chain = chain
        model.content = .loading
        model.selection = nil
        present()
    }

    func show(chain: JavaStreamChain, stages: [[JavaStreamTraceElement]], result: JavaDebugValue?, session: JavaDebugSession) {
        model.chain = chain
        model.session = session
        model.content = .trace(stages: stages, result: result)
        model.selection = nil
        present()
    }

    func showFailure(chain: JavaStreamChain, message: String) {
        model.chain = chain
        model.content = .failure(message)
        present()
    }

    func close() {
        window?.close()
        window = nil
        model.session = nil
    }

    private func present() {
        if window == nil {
            let hosting = NSHostingController(rootView: IDEStreamTraceView(model: model).preferredColorScheme(IDEAppearance.preferredColorScheme))
            let window = NSWindow(contentViewController: hosting)
            window.title = "Stream Trace"
            window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
            window.setContentSize(NSSize(width: 820, height: 460))
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct IDEStreamTraceView: View {
    @Bindable var model: IDEStreamTraceModel

    private static let columnWidth: CGFloat = 170
    private static let gap: CGFloat = 46
    private static let rowHeight: CGFloat = 22
    private static let headerHeight: CGFloat = 28

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(chainText)
                    .font(IDEAppearance.Typography.monoSmall)
                    .lineLimit(2)
                    .textSelection(.enabled)
                Spacer()
                Picker("", selection: $model.isFlat) {
                    Text("Split").tag(false)
                    Text("Flat").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 140)
            }
            .padding(IDEAppearance.Spacing.sm)
            Divider()
            switch model.content {
            case .loading:
                ProgressView("Evaluating the stream…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failure(let message):
                Text(message)
                    .font(IDEAppearance.Typography.body)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            case .trace(let stages, let result):
                if model.isFlat {
                    flat(stages: stages, result: result)
                } else {
                    split(stages: stages, result: result)
                }
            }
            Divider()
            Text("The chain ran again to record each stage, so its side effects happened twice.")
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .padding(.horizontal, IDEAppearance.Spacing.sm)
                .padding(.vertical, 4)
        }
        .frame(minWidth: 480, minHeight: 260)
    }

    private var chainText: String {
        guard let chain = model.chain else { return "" }
        return chain.source + chain.intermediates.map(\.text).joined() + chain.terminal.text
    }

    private var stageNames: [String] {
        model.chain?.stageNames ?? []
    }

    // MARK: Split

    private func split(stages: [[JavaStreamTraceElement]], result: JavaDebugValue?) -> some View {
        let links = model.links(for: stages)
        let related = model.related(stages: stages, links: links)
        let tallest = stages.map(\.count).max() ?? 0
        let width = CGFloat(stages.count) * (Self.columnWidth + Self.gap) + Self.columnWidth
        let height = Self.headerHeight + CGFloat(max(tallest, 1)) * Self.rowHeight + 8
        return ScrollView([.horizontal, .vertical]) {
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    for (stage, stageLinks) in links.enumerated() {
                        for (index, source) in stageLinks.enumerated() {
                            guard let source else { continue }
                            let start = CGPoint(x: x(stage) + Self.columnWidth, y: y(source))
                            let end = CGPoint(x: x(stage + 1), y: y(index))
                            var path = Path()
                            path.move(to: start)
                            path.addCurve(to: end,
                                          control1: CGPoint(x: start.x + Self.gap / 2, y: start.y),
                                          control2: CGPoint(x: end.x - Self.gap / 2, y: end.y))
                            let highlighted = related.contains([stage, source]) && related.contains([stage + 1, index])
                            context.stroke(path, with: .color(highlighted ? .accentColor : .gray.opacity(0.45)),
                                           lineWidth: highlighted ? 2 : 1)
                        }
                    }
                }
                .frame(width: width, height: height)
                ForEach(Array(stages.enumerated()), id: \.offset) { stage, values in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(stage < stageNames.count ? stageNames[stage] : "stage \(stage)")
                            .font(IDEAppearance.Typography.caption.weight(.semibold))
                            .frame(height: Self.headerHeight, alignment: .center)
                        ForEach(Array(values.enumerated()), id: \.offset) { index, element in
                            let isRelated = related.contains([stage, index])
                            Text(element.value)
                                .font(IDEAppearance.Typography.monoSmall)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .padding(.horizontal, 6)
                                .frame(width: Self.columnWidth, height: Self.rowHeight - 2, alignment: .leading)
                                .background(isRelated ? Color.accentColor.opacity(0.25) : IDEAppearance.ColorToken.card,
                                            in: RoundedRectangle(cornerRadius: 4))
                                .padding(.vertical, 1)
                                .onTapGesture { model.selection = (stage, index) }
                                .help(element.value)
                        }
                        if values.isEmpty {
                            Text("nothing")
                                .font(IDEAppearance.Typography.caption)
                                .foregroundStyle(IDEAppearance.ColorToken.muted)
                        }
                    }
                    .frame(width: Self.columnWidth, alignment: .topLeading)
                    .offset(x: x(stage))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.chain?.terminal.name ?? "result")
                        .font(IDEAppearance.Typography.caption.weight(.semibold))
                        .frame(height: Self.headerHeight)
                    if let result, let session = model.session {
                        IDEDebugValueRow(session: session, value: result)
                    } else {
                        Text("void").font(IDEAppearance.Typography.monoSmall).foregroundStyle(IDEAppearance.ColorToken.muted)
                    }
                }
                .frame(width: Self.columnWidth, alignment: .topLeading)
                .offset(x: x(stages.count))
            }
            .frame(width: width, height: height, alignment: .topLeading)
            .padding(IDEAppearance.Spacing.sm)
        }
    }

    private func x(_ stage: Int) -> CGFloat {
        CGFloat(stage) * (Self.columnWidth + Self.gap)
    }

    private func y(_ index: Int) -> CGFloat {
        Self.headerHeight + CGFloat(index) * Self.rowHeight + Self.rowHeight / 2
    }

    // MARK: Flat

    private func flat(stages: [[JavaStreamTraceElement]], result: JavaDebugValue?) -> some View {
        List {
            ForEach(Array(stages.enumerated()), id: \.offset) { stage, values in
                Section(stage < stageNames.count ? stageNames[stage] : "stage \(stage)") {
                    Text(values.map(\.value).joined(separator: ", "))
                        .font(IDEAppearance.Typography.monoSmall)
                        .textSelection(.enabled)
                }
            }
            Section(model.chain?.terminal.name ?? "result") {
                if let result, let session = model.session {
                    IDEDebugValueRow(session: session, value: result)
                } else {
                    Text("void").font(IDEAppearance.Typography.monoSmall)
                }
            }
        }
    }
}
