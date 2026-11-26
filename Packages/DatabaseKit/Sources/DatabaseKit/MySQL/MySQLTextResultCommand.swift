import MySQLNIO
import NIOCore
import NIOConcurrencyHelpers

/// Text queries need the OK packet for affected rows before any diagnostics query can run.
/// The driver's simple query drops that packet and only publishes columns alongside a row.
struct MySQLTextResultCommand: MySQLCommand {
    private enum Step {
        case first, columns(remaining: UInt64), columnTerminator, rows, done
    }

    private struct State {
        var step = Step.first
        var columns: [MySQLProtocol.ColumnDefinition41] = []
    }

    let sql: String
    let onColumns: @Sendable ([MySQLProtocol.ColumnDefinition41]) -> Void
    let onRow: @Sendable (MySQLRow) -> Void
    let onCompletion: @Sendable (UInt64?, UInt16?) -> Void
    private let state = NIOLockedValueBox(State())

    func activate(capabilities: MySQLProtocol.CapabilityFlags) throws -> MySQLCommandState {
        try MySQLCommandState(response: [.encode(MySQLProtocol.COM_QUERY(query: sql), capabilities: capabilities)])
    }

    func handle(packet: inout MySQLPacket, capabilities: MySQLProtocol.CapabilityFlags) throws -> MySQLCommandState {
        if packet.isError {
            let response = try packet.decode(MySQLProtocol.ERR_Packet.self, capabilities: capabilities)
            switch response.errorCode {
            case .DUP_ENTRY: throw MySQLError.duplicateEntry(response.errorMessage)
            case .PARSE_ERROR: throw MySQLError.invalidSyntax(response.errorMessage)
            default: throw MySQLError.server(response)
            }
        }
        return try state.withLockedValue { state in
            switch state.step {
            case .first:
                if packet.isOK {
                    let response = try packet.decode(MySQLProtocol.OK_Packet.self, capabilities: capabilities)
                    onCompletion(response.affectedRows, response.warningsCount)
                    state.step = .done
                    return MySQLCommandState(done: true)
                }
                let result = try packet.decode(MySQLProtocol.COM_QUERY_Response.self, capabilities: capabilities)
                guard result.columnCount > 0 else { throw MySQLError.protocolError }
                state.step = .columns(remaining: result.columnCount)
            case .columns(let remaining):
                let column = try packet.decode(MySQLProtocol.ColumnDefinition41.self, capabilities: capabilities)
                state.columns.append(column)
                if remaining == 1 {
                    onColumns(state.columns)
                    state.step = capabilities.contains(.CLIENT_DEPRECATE_EOF) ? .rows : .columnTerminator
                } else {
                    state.step = .columns(remaining: remaining - 1)
                }
            case .columnTerminator:
                guard packet.isEOF else { throw MySQLError.protocolError }
                state.step = .rows
            case .rows:
                // An eight-byte length-coded first field also starts with 0xFE, but it then
                // carries at least 16 MiB of field data.
                if packet.isEOF, packet.payload.readableBytes < 0x00ff_ffff {
                    let warnings: UInt16?
                    if capabilities.contains(.CLIENT_DEPRECATE_EOF) {
                        warnings = try packet.decode(MySQLProtocol.OK_Packet.self, capabilities: capabilities).warningsCount
                    } else {
                        warnings = packet.payload.getInteger(at: packet.payload.readerIndex + 1, endianness: .little)
                    }
                    onCompletion(nil, warnings)
                    state.step = .done
                    return MySQLCommandState(done: true)
                }
                let row = try MySQLProtocol.TextResultSetRow.decode(from: &packet, columnCount: state.columns.count)
                onRow(MySQLRow(format: .text, columnDefinitions: state.columns, values: row.values))
            case .done:
                throw MySQLError.protocolError
            }
            return MySQLCommandState()
        }
    }
}
