import SwiftUI

public struct CounterView: View {
    @State private var count = 0
    public init() {}

    func caption() -> String { "caption-original" }

    public var body: some View {
        VStack(spacing: 12) {
            Text("Count: \(count)").font(.title)
            Button("Add") { count += 1 }
            Helper.label
            Text(caption())
        }
        .padding(30)
    }
}

private enum Helper {
    static var label: some View { Text("v1").foregroundStyle(.secondary) }
}
