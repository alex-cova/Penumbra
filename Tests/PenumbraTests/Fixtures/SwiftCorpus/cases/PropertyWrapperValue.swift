import SwiftUI
struct V: View {
    @State var count = 0
    var body: some View { Text("a").onTapGesture { count./*|*/ } }
}
//! contains: description, magnitude
