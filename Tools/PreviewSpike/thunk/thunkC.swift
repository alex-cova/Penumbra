@_private(sourceFile: "CounterView.swift") import ToyKit
import PreviewSupport
import SwiftUI
extension CounterView {
    @_dynamicReplacement(for: body)
    private var __preview__body: some View {
        let _ = UmbraReload.shared.generation
        return VStack(spacing: 12) {
            Text("Count: \(count)").font(.title).foregroundStyle(.red)
            Button("Add") { count += 1 }
            Helper.label
            Text("v3 token")
        }.padding(30)
    }
}
