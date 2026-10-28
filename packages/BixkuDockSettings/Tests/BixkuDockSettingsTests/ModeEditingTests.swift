import BixkuDock
import XCTest
@testable import BixkuDockSettings

final class ModeEditingTests: XCTestCase {
    private func makeEditor() -> (ModeStoreEditor, InMemoryModeBackend) {
        let backend = InMemoryModeBackend()
        return (ModeStoreEditor(store: JSONModeStore(backend: backend)), backend)
    }

    func testSaveCreatesUserModeAndOverridesFactoryMode() async throws {
        let (editor, _) = makeEditor()
        try await editor.save(ModeDefinition(id: "focus", name: "Focus", symbol: "bolt", summary: "Heads down."))

        var writing = try XCTUnwrap(DefaultModes.definition(.writing))
        writing.name = "My writing"
        try await editor.save(writing)

        let catalog = try await editor.loadCatalog()
        XCTAssertEqual(catalog.mode("focus")?.provenance, .user)
        XCTAssertEqual(catalog.mode(.writing)?.provenance, .userOverride)
        XCTAssertEqual(catalog.mode(.writing)?.name, "My writing")
    }

    func testRestoreFactoryDropsTheOverrideOnly() async throws {
        let (editor, _) = makeEditor()
        var writing = try XCTUnwrap(DefaultModes.definition(.writing))
        writing.name = "My writing"
        try await editor.save(writing)

        try await editor.restoreFactory(.writing)
        let catalog = try await editor.loadCatalog()
        XCTAssertEqual(catalog.mode(.writing)?.provenance, .factory)
        XCTAssertEqual(catalog.definition(.writing), DefaultModes.definition(.writing))

        // Restoring something already at factory state is a no-op, not an error.
        try await editor.restoreFactory(.writing)
    }

    func testRestoreFactoryRejectsUserAndUnknownModes() async throws {
        let (editor, _) = makeEditor()
        try await editor.save(ModeDefinition(id: "focus", name: "Focus", symbol: "bolt", summary: "Heads down."))

        do {
            try await editor.restoreFactory("focus")
            XCTFail("expected an error")
        } catch let error as ModeEditingError {
            XCTAssertEqual(error, .noFactoryVersion("focus"))
        }
        do {
            try await editor.restoreFactory("ghost")
            XCTFail("expected an error")
        } catch let error as ModeStoreError {
            XCTAssertEqual(error, .unknownMode("ghost"))
        }
    }

    func testRestoreAllFactoryKeepsUserModes() async throws {
        let (editor, _) = makeEditor()
        try await editor.save(ModeDefinition(id: "focus", name: "Focus", symbol: "bolt", summary: "Heads down."))
        for id in [ModeID.writing, .building] {
            var definition = try XCTUnwrap(DefaultModes.definition(id))
            definition.name = "Custom \(id)"
            try await editor.save(definition)
        }

        try await editor.restoreAllFactory()
        let catalog = try await editor.loadCatalog()
        XCTAssertEqual(catalog.mode("focus")?.provenance, .user)
        XCTAssertEqual(catalog.mode(.writing)?.provenance, .factory)
        XCTAssertEqual(catalog.mode(.building)?.provenance, .factory)
    }

    func testDeleteUserModeAndFactoryModeRules() async throws {
        let (editor, _) = makeEditor()
        try await editor.save(ModeDefinition(id: "focus", name: "Focus", symbol: "bolt", summary: "Heads down."))
        try await editor.delete("focus")
        let catalog = try await editor.loadCatalog()
        XCTAssertNil(catalog.mode("focus"))

        do {
            try await editor.delete(.writing)
            XCTFail("factory modes cannot be deleted")
        } catch let error as ModeStoreError {
            XCTAssertEqual(error, .cannotDeleteFactoryMode(.writing))
        }
    }

    func testInvalidDefinitionIsRejectedBySave() async throws {
        let (editor, _) = makeEditor()
        do {
            try await editor.save(ModeDefinition(id: "Bad Id", name: "", symbol: "bolt", summary: "x"))
            XCTFail("expected a validation error")
        } catch let error as ModeStoreError {
            guard case .invalid(let validation) = error else { return XCTFail("\(error)") }
            XCTAssertFalse(validation.issues.isEmpty)
        }
    }

    func testCatalogChangesStreamsSaves() async throws {
        let (editor, _) = makeEditor()
        var iterator = editor.catalogChanges().makeAsyncIterator()
        try await editor.save(ModeDefinition(id: "focus", name: "Focus", symbol: "bolt", summary: "Heads down."))
        let catalog = await iterator.next()
        XCTAssertNotNil(catalog?.mode("focus"))
    }

    // MARK: Locations and permissions

    func testModesDirectoryIsDerivedAtRuntime() {
        let derived = ModeLocations.modesDirectory()
        XCTAssertEqual(derived.lastPathComponent, "modes")
        XCTAssertEqual(derived.deletingLastPathComponent().lastPathComponent, "dock")
        XCTAssertTrue(derived.path.contains(ModeLocations.appFolderName))

        let custom = URL(fileURLWithPath: "/tmp/example-data", isDirectory: true)
        XCTAssertEqual(
            ModeLocations.modesDirectory(dataDirectory: custom).path,
            "/tmp/example-data/dock/modes"
        )
    }

    func testPermissionURLsAreWellFormedSystemSettingsLinks() {
        for permission in DockPermission.allCases {
            XCTAssertEqual(permission.settingsURL?.scheme, "x-apple.systempreferences", "\(permission)")
            XCTAssertEqual(permission.fallbackSettingsURL?.scheme, "x-apple.systempreferences", "\(permission)")
            XCTAssertFalse(permission.rationale.isEmpty)
        }
        XCTAssertTrue(DockPermission.accessibility.settingsURLString.hasSuffix("Privacy_Accessibility"))
        XCTAssertTrue(DockPermission.notifications.settingsURLString.contains("Notifications"))
    }
}
