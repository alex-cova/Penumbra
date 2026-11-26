import DatabaseKit
import Foundation

enum IDEDatabaseConnectionDiagnostics {
    static func message(_ error: String, engine: DatabaseEngine) -> String {
        let detail = SecretRedactor.redact(error)
        let text = detail.lowercased()
        let next: String
        if engine == .sqlite {
            next = text.contains("lock") || text.contains("busy")
                ? "Close the application holding the database lock, or increase the busy timeout and retry."
                : "Check that the path points to a SQLite database and that Umbra can access the file and its folder."
        } else if ["certificate", "ssl", "tls"].contains(where: text.contains) {
            next = "Check the TLS mode, certificate trust, and the host name on the certificate."
        } else if ["password", "authentication", "access denied", "sasl"].contains(where: text.contains) {
            next = "Check the username, password, and authentication database."
        } else if ["unknown database", "database does not exist", "3d000"].contains(where: text.contains) {
            next = "Check the database name and your account’s access."
        } else if ["dns", "resolve", "getaddrinfo", "name or service"].contains(where: text.contains) {
            next = "Check the host name and DNS or SRV configuration."
        } else {
            next = "Check the host, port, and network access to the server."
        }
        return "\(detail)\n\n\(next)"
    }
}
