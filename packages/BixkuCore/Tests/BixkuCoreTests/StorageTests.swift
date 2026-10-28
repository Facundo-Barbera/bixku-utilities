import XCTest
@testable import BixkuCore

private struct Mode: Codable, Equatable {
    var id: String
    var blockedApps: [String]
}

final class StorageTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = try makeTemporaryDirectory()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func exerciseStorage(_ storage: any ModuleStorage) async throws {
        let mode = Mode(id: "writing", blockedApps: ["com.example.chat"])
        let missing = try await storage.value(Mode.self, forKey: "writing")
        XCTAssertNil(missing)
        try await storage.setValue(mode, forKey: "writing")
        try await storage.setValue(1, forKey: "schema-version")
        let loaded = try await storage.value(Mode.self, forKey: "writing")
        XCTAssertEqual(loaded, mode)
        let keys = try await storage.keys()
        XCTAssertEqual(keys, ["schema-version", "writing"])
        try await storage.removeValue(forKey: "writing")
        let removed = try await storage.value(Mode.self, forKey: "writing")
        XCTAssertNil(removed)
        try await storage.removeValue(forKey: "never-set")

        for bad in ["", "../escape", "a/b", ".hidden", "with space"] {
            await assertThrows(StorageError.invalidKey(bad)) {
                try await storage.setValue(1, forKey: bad)
            }
        }
    }

    func testInMemoryStorage() async throws {
        try await exerciseStorage(InMemoryModuleStorage())
    }

    func testFileStorage() async throws {
        let storageDirectory = directory.appendingPathComponent("data")
        try await exerciseStorage(FileModuleStorage(directory: storageDirectory))

        // Data survives a new instance.
        let first = FileModuleStorage(directory: storageDirectory)
        try await first.setValue(Mode(id: "building", blockedApps: []), forKey: "building")
        let second = FileModuleStorage(directory: storageDirectory)
        let loaded = try await second.value(Mode.self, forKey: "building")
        XCTAssertEqual(loaded?.id, "building")
        XCTAssertTrue(FileManager.default.fileExists(atPath: storageDirectory.appendingPathComponent("building.json").path))
    }

    func testFileStorageWithoutDirectoryIsEmpty() async throws {
        let storage = FileModuleStorage(directory: directory.appendingPathComponent("not-created"))
        let keys = try await storage.keys()
        XCTAssertEqual(keys, [])
    }

    private func exerciseSettings(_ settings: any SettingsStore) async throws {
        let changes = settings.changes()
        try await settings.setValue(true, forKey: "enabled")
        try await settings.setValue(true, forKey: "enabled")  // unchanged: no notification
        try await settings.setValue("writing", forKey: "default-mode")
        try await settings.setValue(nil, forKey: "enabled")
        let received = await collect(changes, count: 3)
        XCTAssertEqual(received, [
            SettingsChange(key: "enabled", newValue: true),
            SettingsChange(key: "default-mode", newValue: "writing"),
            SettingsChange(key: "enabled", newValue: nil),
        ])
        let all = try await settings.allValues()
        XCTAssertEqual(all, ["default-mode": "writing"])
        await assertThrows(StorageError.invalidKey("a/b")) {
            try await settings.setValue(1, forKey: "a/b")
        }
    }

    func testInMemorySettings() async throws {
        try await exerciseSettings(InMemorySettingsStore())
    }

    func testFileSettingsPersist() async throws {
        let file = directory.appendingPathComponent("nested/settings.json")
        try await exerciseSettings(JSONFileSettingsStore(fileURL: file))
        let reopened = JSONFileSettingsStore(fileURL: file)
        let value = try await reopened.value(forKey: "default-mode")
        XCTAssertEqual(value, "writing")
        try await reopened.setValue(["a": [1, 2.5, false]], forKey: "complex")
        let again = try await JSONFileSettingsStore(fileURL: file).value(forKey: "complex")
        XCTAssertEqual(again, ["a": [1, 2.5, false]])
    }

    func testFileStorageFactoryLayoutAndSharing() async throws {
        let factory = FileStorageFactory(rootDirectory: directory)
        let storage = try factory.storage(for: "online.bixku.dock")
        try await storage.setValue("x", forKey: "state")
        let settings = try factory.settings(for: "online.bixku.dock")
        try await settings.setValue(1, forKey: "level")

        let moduleDirectory = directory.appendingPathComponent("online.bixku.dock")
        XCTAssertTrue(FileManager.default.fileExists(atPath: moduleDirectory.appendingPathComponent("data/state.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: moduleDirectory.appendingPathComponent("settings.json").path))

        // Same instance for the same module, so the UI and the module see the same changes.
        let again = try factory.settings(for: "online.bixku.dock")
        XCTAssertTrue((again as AnyObject) === (settings as AnyObject))

        XCTAssertThrowsError(try factory.storage(for: ModuleID(rawValue: "../evil")))
    }

    func testInMemoryFactorySharesPerModule() throws {
        let factory = InMemoryStorageFactory()
        let a1 = try factory.storage(for: "a")
        let a2 = try factory.storage(for: "a")
        let b = try factory.storage(for: "b")
        XCTAssertTrue((a1 as AnyObject) === (a2 as AnyObject))
        XCTAssertFalse((a1 as AnyObject) === (b as AnyObject))
    }
}
