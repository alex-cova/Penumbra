@_private(sourceFile: "CounterView.swift") import ToyKit
import SwiftUI
extension CounterView {
    @_dynamicReplacement(for: body)
    private var __preview__body: some View {
        VStack(spacing: 12) {
            Text("Count: \(count)").font(.title).foregroundStyle(.red)
            Button("Add") { count += 1 }
            Helper.label
            Text("v2 body replaced")
        }.padding(30)
    }
}
