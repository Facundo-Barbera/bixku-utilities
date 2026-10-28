import BixkuCore
import Foundation
import XCTest
@testable import BixkuDock

final class ModeStoreTests: XCTestCase {
    func testEmptyStoreResolvesFactoryModes() async throws {
        let store = JSONModeStore(backend: InMemoryModeBackend())
        let catalog = try await store.load()
        XCTAssertEqual(catalog.ids, DefaultModes.all.map(\.id))
        XCTAssertTrue(catalog.modes.allSatisfy { $0.provenance == .factory })
        XCTAssertEqual(catalog.issues, [])
        XCTAssertEqual(catalog, ModeCatalog.factory)
    }

    func testUserModesAndOverridesOnDisk() async throws {
        let directory = try makeTemporaryDirectory().appendingPathComponent("modes", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let store = JSONModeStore(directory: directory)

        var writing = DefaultModes.definition(.writing)!
        writing.notifications.defaultAction = .silence
        try await store.save(writing)
        try await store.save(makeMode("deep-work", transitions: [ModeRule(trigger: .idle, forSeconds: 60, from: ["writing"])]))
        try await store.save(makeMode("admin"))

        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        XCTAssertEqual(files, ["admin.json", "deep-work.json", "writing.json"])
        let text = try String(contentsOf: directory.appendingPathComponent("writing.json"), encoding: .utf8)
        XCTAssertTrue(text.contains("\"schemaVersion\" : 1"), text)

        // A fresh store over the same directory sees the same catalog.
        let catalog = try await JSONModeStore(directory: directory).load()
        XCTAssertEqual(catalog.ids, DefaultModes.all.map(\.id) + ["admin", "deep-work"])
        XCTAssertEqual(catalog.mode(.writing)?.provenance, .userOverride)
        XCTAssertEqual(catalog.definition(.writing)?.notifications.defaultAction, .silence)
        XCTAssertEqual(catalog.mode("admin")?.provenance, .user)
        XCTAssertEqual(catalog.mode(.building)?.provenance, .factory)

        // Deleting the override restores the factory mode.
        try await store.delete(.writing)
        let restored = try await store.load()
        XCTAssertEqual(restored.mode(.writing)?.provenance, .factory)
        XCTAssertEqual(restored.definition(.writing), DefaultModes.definition(.writing))
    }

    func testDeleteErrors() async throws {
        let store = JSONModeStore(backend: InMemoryModeBackend())
        do {
            try await store.delete(.building)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? ModeStoreError, .cannotDeleteFactoryMode(.building))
        }
        do {
            try await store.delete("ghost")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? ModeStoreError, .unknownMode("ghost"))
        }
    }

    func testSaveRejectsInvalidModes() async throws {
        let backend = InMemoryModeBackend()
        let store = JSONModeStore(backend: backend)
        var mode = makeMode("broken", transitions: [ModeRule(trigger: .activity, forSeconds: 10, from: ["nowhere"])])
        mode.name = ""
        do {
            try await store.save(mode)
            XCTFail("expected an error")
        } catch let ModeStoreError.invalid(error) {
            XCTAssertEqual(error.issues.map(\.path), ["name", "transitions[0].match", "transitions[0].from[0]"])
        }
        let ids = await backend.documentIDs()
        XCTAssertEqual(ids, [])
    }

    func testSaveUpgradesSchemaVersion() async throws {
        let backend = InMemoryModeBackend()
        var mode = makeMode("old")
        mode.schemaVersion = 0
        try await JSONModeStore(backend: backend).save(mode)
        let data = try await XCTUnwrapAsync(await backend.readDocument("old"))
        XCTAssertEqual(try JSONDecoder().decode(ModeDefinition.self, from: data).schemaVersion, 1)
    }

    func testInvalidDocumentsAreSkippedAndReported() async throws {
        let good = try JSONModeStore.encode(makeMode("good"))
        var badBuilding = DefaultModes.definition(.building)!
        badBuilding.transitions[0].forSeconds = -5
        let backend = InMemoryModeBackend(documents: [
            "good": good,
            "building": try JSONModeStore.encode(badBuilding),
            "garbage": json("{not json"),
            "renamed": good,
            "future": json(#"{"schemaVersion":99,"id":"future","name":"F","description":"d"}"#),
            "legacy": json(#"{"id":"legacy","name":"Legacy","description":"Written before schemaVersion existed"}"#),
        ])
        let catalog = try await JSONModeStore(backend: backend).load()
        XCTAssertTrue(catalog.contains("good"))
        XCTAssertTrue(catalog.contains("legacy"))
        XCTAssertFalse(catalog.contains("future"))
        // The invalid override is ignored: the factory definition stays in effect.
        XCTAssertEqual(catalog.mode(.building)?.provenance, .factory)
        let byDocument = Dictionary(uniqueKeysWithValues: catalog.issues.map { ($0.document, $0.message) })
        XCTAssertEqual(Set(byDocument.keys), ["building", "garbage", "renamed", "future"])
        XCTAssertEqual(byDocument["building"], "transitions[0].forSeconds: must be greater than 0")
        XCTAssertEqual(byDocument["renamed"], "id 'good' does not match the document name 'renamed'")
        XCTAssertTrue(byDocument["future"]?.contains("newer than this app supports") == true)
        XCTAssertTrue(byDocument["garbage"]?.hasPrefix("not valid JSON") == true)
    }

    func testCrossReferencesBetweenUserModes() async throws {
        let backend = InMemoryModeBackend(documents: [
            "a": try JSONModeStore.encode(makeMode("a", transitions: [ModeRule(trigger: .idle, forSeconds: 5, from: ["b"])])),
            "b": try JSONModeStore.encode(makeMode("b")),
        ])
        let catalog = try await JSONModeStore(backend: backend).load()
        XCTAssertEqual(catalog.issues, [])
        XCTAssertTrue(catalog.contains("a"))
    }

    func testStorageBackendUsesModuleStorage() async throws {
        let storage = InMemoryModuleStorage()
        let store = JSONModeStore(backend: StorageModeBackend(storage: storage))
        try await store.save(makeMode("focus"))
        try await storage.setValue(["unrelated": true], forKey: "settings-cache")
        let keys = try await storage.keys()
        XCTAssertEqual(keys, ["mode.focus", "settings-cache"])
        let catalog = try await store.load()
        XCTAssertEqual(catalog.mode("focus")?.provenance, .user)
        try await store.delete("focus")
        let after = try await store.load()
        XCTAssertFalse(after.contains("focus"))
    }

    func testChangesStreamEmitsAfterWrites() async throws {
        let store = JSONModeStore(backend: InMemoryModeBackend())
        let changes = store.changes()
        try await store.save(makeMode("one"))
        var iterator = changes.makeAsyncIterator()
        let first = await iterator.next()
        XCTAssertTrue(first?.contains("one") == true)
        try await store.delete("one")
        let second = await iterator.next()
        XCTAssertEqual(second?.contains("one"), false)
    }
}

func XCTUnwrapAsync<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
    try XCTUnwrap(value, file: file, line: line)
}
