import Foundation

/// A JSON Web Token taken apart for reading. The signature is never checked: this only shows what
/// the token claims, and says so.
struct IDEJWTDecoding: Identifiable, Equatable {
    /// A time claim (`iat`, `nbf`, `exp`) with the moment it names.
    struct TimeClaim: Equatable {
        let name: String
        let date: Date
    }

    enum Status: Equatable {
        case noExpiry
        case valid(until: Date)
        case expired(at: Date)
        case notYetValid(from: Date)
    }

    let id = UUID()
    /// The header as pretty-printed JSON, key order kept.
    let header: String
    let payload: String
    /// The signature as written (Base64URL); empty for an unsecured (`alg: none`) token.
    let signature: String
    let algorithm: String?
    let timeClaims: [TimeClaim]
    let status: Status
    /// Where the token was selected in the editor, for "Insert as Comment".
    var anchorOffset: Int?

    /// The text Copy puts on the clipboard.
    var summary: String {
        "// header\n\(header)\n// payload\n\(payload)"
    }

    static func == (lhs: IDEJWTDecoding, rhs: IDEJWTDecoding) -> Bool {
        lhs.id == rhs.id
    }
}

enum IDEJWTText {
    private static let timeClaimNames = ["iat", "nbf", "exp"]

    /// Decodes `text` as a JWT: three dot-separated parts whose first two are Base64URL JSON
    /// objects. Whitespace, surrounding quotes and a `Bearer ` (or `Authorization: Bearer `) prefix
    /// are ignored. `nil` when it is not a JWT (an encrypted JWE has five parts and is refused).
    static func decode(_ text: String, now: Date = Date()) -> IDEJWTDecoding? {
        guard let token = cleaned(text) else { return nil }
        let parts = token.components(separatedBy: ".")
        guard parts.count == 3, !parts[0].isEmpty, !parts[1].isEmpty,
              let headerText = IDEBase64Text.decode(parts[0]), let payloadText = IDEBase64Text.decode(parts[1]),
              let header = jsonObject(headerText), let payload = jsonObject(payloadText),
              let prettyHeader = IDEJSONText.format(headerText), let prettyPayload = IDEJSONText.format(payloadText)
        else { return nil }

        let claims: [IDEJWTDecoding.TimeClaim] = timeClaimNames.compactMap { name in
            guard let number = payload[name] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            return .init(name: name, date: Date(timeIntervalSince1970: number.doubleValue))
        }
        let expiry = claims.first { $0.name == "exp" }?.date
        let notBefore = claims.first { $0.name == "nbf" }?.date
        let status: IDEJWTDecoding.Status
        if let expiry, expiry <= now {
            status = .expired(at: expiry)
        } else if let notBefore, notBefore > now {
            status = .notYetValid(from: notBefore)
        } else if let expiry {
            status = .valid(until: expiry)
        } else {
            status = .noExpiry
        }
        return IDEJWTDecoding(
            header: prettyHeader, payload: prettyPayload, signature: parts[2],
            algorithm: header["alg"] as? String, timeClaims: claims, status: status)
    }

    private static func cleaned(_ text: String) -> String? {
        var token = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = token.range(of: "bearer ", options: [.caseInsensitive]) {
            token = String(token[range.upperBound...])
        }
        token = token.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`").union(.whitespacesAndNewlines))
        token = String(token.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) })
        return token.isEmpty ? nil : token
    }

    private static func jsonObject(_ text: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }
}
