import Foundation
import Testing

@testable import DatabaseCore

struct ResultStoreTests {
    private func makeRows(_ range: Range<Int>) -> [[DatabaseValue]] {
        range.map { [.int(Int64($0)), .text("row-\($0)"), $0 % 7 == 0 ? .null : .double(Double($0) / 4)] }
    }

    private let columns = [ResultColumn(name: "id"), ResultColumn(name: "label"), ResultColumn(name: "x")]

    @Test func readsBackWhatWasAppended() async throws {
        let store = ResultStore(columns: columns)
        try await store.append(makeRows(0..<2_500))
        await store.finish()
        #expect(await store.rowCount == 2_500)
        let all = try await store.rows(in: 0..<2_500)
        #expect(all == makeRows(0..<2_500))
        // Ranges crossing chunk boundaries and the unsealed tail.
        #expect(try await store.rows(in: 1_020..<1_030) == makeRows(1_020..<1_030))
        #expect(try await store.rows(in: 2_040..<2_500) == makeRows(2_040..<2_500))
        // Clamped, not an error.
        #expect(try await store.rows(in: 2_490..<9_999) == makeRows(2_490..<2_500))
        #expect(try await store.rows(in: 5_000..<6_000).isEmpty)
        await store.close()
    }

    @Test func sparseProjectionPreservesOrderAcrossSpilledChunks() async throws {
        let store = ResultStore(columns: [], memoryLimitBytes: 0)
        try await store.append((0..<2_100).map { [.int(Int64($0))] })
        await store.finish()
        let stats = await store.stats
        #expect(stats.spillFileExists)
        let selected = try await store.mapRows(at: [2_099, 0, 1_024, 0, 2_000]) { $0.first }
        #expect(selected == [.int(2_099), .int(0), .int(1_024), .int(0), .int(2_000)])
        await store.close()
    }

    @Test func memoryStaysUnderTheCeilingAndOldChunksSpillAndComeBack() async throws {
        // A ceiling of one chunk's worth forces spilling almost immediately.
        let store = ResultStore(columns: columns, memoryLimitBytes: 200_000)
        for start in stride(from: 0, to: 20_480, by: 1_024) {
            try await store.append(makeRows(start..<(start + 1_024)))
        }
        let stats = await store.stats
        #expect(stats.rowCount == 20_480)
        #expect(stats.spilledBytes > 0)
        #expect(stats.spillFileExists)
        // Resident bytes never exceed the ceiling by more than the chunk being protected.
        #expect(stats.residentBytes <= 200_000 + 400_000, "resident \(stats.residentBytes)")

        // Reading an early, spilled range returns exactly the original rows.
        #expect(try await store.rows(in: 0..<50) == makeRows(0..<50))
        #expect(try await store.row(at: 10_000) == makeRows(10_000..<10_001)[0])
        // And reading everything again still matches, in order.
        let all = try await store.rows(in: 0..<20_480)
        #expect(all.count == 20_480)
        #expect(all[20_479] == makeRows(20_479..<20_480)[0])
        let after = await store.stats
        #expect(after.residentBytes <= 200_000 + 400_000, "resident after reads \(after.residentBytes)")
        await store.close()
    }

    @Test func closingDeletesTheSpillFileAndLaterReadsThrow() async throws {
        let store = ResultStore(columns: columns, memoryLimitBytes: 1)
        try await store.append(makeRows(0..<3_000))
        let path = try await spillPath(of: store)
        #expect(FileManager.default.fileExists(atPath: path))
        await store.close()
        #expect(!FileManager.default.fileExists(atPath: path))
        await #expect(throws: ResultStoreError.closed) {
            _ = try await store.rows(in: 0..<10)
        }
        await #expect(throws: ResultStoreError.closed) {
            try await store.append(self.makeRows(0..<1))
        }
    }

    @Test func oversizedRowsSealByteLimitedChunksAndProjectAcrossSpills() async throws {
        let store = ResultStore(columns: columns, memoryLimitBytes: 128_000)
        let largeValue = DatabaseValue.text(String(repeating: "x", count: 60_000))
        let rows = (0..<17).map { [DatabaseValue.int(Int64($0)), $0.isMultiple(of: 3) ? largeValue : .null] }
        try await store.append(rows)
        let stats = await store.stats
        #expect(stats.spillFileExists)
        #expect(stats.chunkCount > 1)
        #expect(stats.residentBytes < 200_000)
        #expect(try await store.rows(in: 2..<17) == Array(rows[2..<17]))
        let ids = try await store.mapRows(in: 4..<14) { $0[0] }
        #expect(ids == (4..<14).map { .int(Int64($0)) })
        await store.close()
    }

    @Test func releasingTheStoreAlsoDeletesTheSpillFile() async throws {
        var path = ""
        do {
            let store = ResultStore(columns: columns, memoryLimitBytes: 1)
            try await store.append(makeRows(0..<3_000))
            path = try await spillPath(of: store)
            #expect(FileManager.default.fileExists(atPath: path))
        }
        // Actor deinit runs after the last reference is gone; give the runtime a moment.
        for _ in 0..<50 where FileManager.default.fileExists(atPath: path) {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func spillFilesAreOwnerOnly() async throws {
        let store = ResultStore(columns: columns, memoryLimitBytes: 1)
        try await store.append(makeRows(0..<3_000))
        let path = try await spillPath(of: store)
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        await store.close()
    }

    @Test func rowLimitStopsTheProducer() async throws {
        let store = ResultStore(columns: columns, rowLimit: 1_500)
        let first = try await store.append(makeRows(0..<1_000))
        #expect(first)
        let second = try await store.append(makeRows(1_000..<2_000))
        #expect(!second, "append must tell the producer to stop at the limit")
        #expect(await store.rowCount == 1_500)
        #expect(await store.limitReached)
        // Further appends are refused without error.
        #expect(try await store.append(makeRows(0..<10)) == false)
        #expect(await store.rowCount == 1_500)
        await store.close()
    }

    @Test func specialFloatsSurviveASpill() async throws {
        let store = ResultStore(columns: [ResultColumn(name: "d")], memoryLimitBytes: 1)
        let rows: [[DatabaseValue]] = (0..<2_100).map { index in
            switch index % 3 {
            case 0: [.double(.infinity)]
            case 1: [.double(-.infinity)]
            default: [.double(.nan)]
            }
        }
        try await store.append(rows)
        let back = try await store.rows(in: 0..<3)
        #expect(back[0] == [.double(.infinity)])
        #expect(back[1] == [.double(-.infinity)])
        if case .double(let value) = back[2][0] { #expect(value.isNaN) } else { Issue.record("expected a double") }
        await store.close()
    }

    /// This store's own spill file. Tests run in parallel, so the path comes from the store
    /// rather than from guessing in the shared temporary directory.
    private func spillPath(of store: ResultStore) async throws -> String {
        try #require(await store.stats.spillFilePath)
    }
}
