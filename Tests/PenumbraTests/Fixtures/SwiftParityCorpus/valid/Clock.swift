import Foundation

func timestamp() -> String {
    let formatter = DateFormatter()
    return formatter.string(from: Date())
}
