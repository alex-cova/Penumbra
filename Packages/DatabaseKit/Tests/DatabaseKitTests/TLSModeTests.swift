import Foundation
import Testing

@testable import DatabaseKit

struct TLSModeTests {
    @Test func aPlainPostgresURLMeansPreferNotRequire() throws {
        let draft = try DatabaseURL.parse("postgresql://app:pw@db.example.com:5432/shop")
        #expect(draft.connection.useTLS, "libpq's default is prefer: TLS if offered")
        #expect(draft.connection.tlsRequired == nil)
        #expect(draft.connection.sqlLogin(password: "pw").requireTLS == false)
    }

    @Test func sslmodeRequireBecomesStrictTLS() throws {
        let draft = try DatabaseURL.parse("postgresql://app:pw@db.example.com/shop?sslmode=require")
        #expect(draft.connection.tlsRequired == true)
        let login = draft.connection.sqlLogin(password: "pw")
        #expect(login.requireTLS)
        #expect(login.useTLS)
    }

    @Test func sslmodeDisableMeansNoTLS() throws {
        let draft = try DatabaseURL.parse("postgresql://app:pw@localhost/shop?sslmode=disable")
        #expect(!draft.connection.useTLS)
        #expect(draft.connection.tlsRequired == nil)
    }

    @Test func connectionFilesSavedBeforeTheOptionExistedStillLoadWithTheirOldMeaning() throws {
        let old = """
        {"id":"6A3E9C1C-3B0A-4C55-9B7E-1F2D3C4B5A69","name":"prod","engine":"postgres","host":"h","port":5432,
         "username":"u","database":"d","useTLS":true,"readOnly":false,"authSource":"admin","useSRV":false,
         "replicaSet":"","directConnection":true,"lastStatement":"","sortIndex":0}
        """
        let connection = try JSONDecoder().decode(DatabaseConnection.self, from: Data(old.utf8))
        #expect(connection.useTLS)
        #expect(connection.tlsRequired == nil)
        let login = connection.sqlLogin(password: "")
        #expect(login.useTLS && !login.requireTLS, "an old connection keeps 'prefer'; it is not silently made strict")
    }

    @Test func strictTLSRoundTripsThroughTheConnectionFile() throws {
        let connection = DatabaseConnection(name: "n", engine: .postgres, useTLS: true, tlsRequired: true)
        let data = try JSONEncoder().encode(connection)
        let back = try JSONDecoder().decode(DatabaseConnection.self, from: data)
        #expect(back.tlsRequired == true)
    }
}
