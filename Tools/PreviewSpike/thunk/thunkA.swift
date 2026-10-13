@_private(sourceFile: "CounterView.swift") import ToyKit
import SwiftUI
extension CounterView {
    @_dynamicReplacement(for: caption())
    private func __preview__caption() -> String { "caption-REPLACED" }
}
