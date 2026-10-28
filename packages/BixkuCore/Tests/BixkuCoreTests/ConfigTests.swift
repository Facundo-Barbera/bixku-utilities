import XCTest
@testable import BixkuCore

final class ConfigTests: XCTestCase {
    func testParsesTheSupportedTOMLSubset() throws {
        let toml = """
        # Comment
        title = "Bixku" # trailing comment

        [general]
        log_level = 'info'
        retries = 3
        ratio = -0.5
        big = 1_000
        exp = 1e3
        enabled = true
        "quoted key" = "a \\"quoted\\" \\u00e9 value"

        [modules.dock]
        apps = [
          "com.example.one", # first
          "com.example.two",
        ]
        nested = [[1, 2], []]
        point = { x = 1, y = { z = "deep" } }

        [modules.dock.privacy]
        redact = []
        """
        let config = try StaticConfigProvider(toml: toml)
        XCTAssertEqual(config.string("title"), "Bixku")
        XCTAssertEqual(config.string("general.log_level"), "info")
        XCTAssertEqual(config.int("general.retries"), 3)
        XCTAssertEqual(config.double("general.ratio"), -0.5)
        XCTAssertEqual(config.int("general.big"), 1000)
        XCTAssertEqual(config.double("general.exp"), 1000)
        XCTAssertEqual(config.double("general.retries"), 3)
        XCTAssertEqual(config.bool("general.enabled"), true)
        XCTAssertEqual(config.value(forKeyPath: "general")?.tableValue?["quoted key"], "a \"quoted\" é value")
        XCTAssertEqual(config.strings("modules.dock.apps"), ["com.example.one", "com.example.two"])
        XCTAssertEqual(config.value(forKeyPath: "modules.dock.nested"), [[1, 2], []])
        XCTAssertEqual(config.string("modules.dock.point.y.z"), "deep")
        XCTAssertEqual(config.value(forKeyPath: "modules.dock.privacy.redact"), [])

        let dock = config.scoped(to: "modules.dock")
        XCTAssertEqual(dock.string("point.y.z"), "deep")
        XCTAssertNotNil(dock.value(forKeyPath: "")?.tableValue)
        XCTAssertNil(config.value(forKeyPath: "modules.missing.key"))
    }

    func testParsesTheExampleConfigShape() throws {
        // Mirrors config.example.toml so changes there stay parseable.
        let toml = """
        [general]
        data_dir = "~/Library/Application Support/BixkuUtilities"
        log_level = "info"            # trace | debug | info | warn | error

        [llm]
        provider = "anthropic"
        base_url = ""
        request_timeout_seconds = 20

        [modules.dock]
        enabled = true
        activity_sample_interval = 2.0

        [modules.dock.privacy]
        redact_window_titles_for = ["com.example.PasswordManager"]

        [modules.lintel]
        enabled = false
        """
        let config = try StaticConfigProvider(toml: toml)
        XCTAssertEqual(LogLevel(name: config.string("general.log_level") ?? ""), .info)
        XCTAssertEqual(config.double("modules.dock.activity_sample_interval"), 2.0)
        XCTAssertEqual(config.bool("modules.lintel.enabled"), false)
        XCTAssertEqual(config.int("llm.request_timeout_seconds"), 20)
    }

    func testRejectsInvalidOrUnsupportedTOML() {
        let cases: [(String, Int)] = [
            ("a = ", 1),
            ("a = 1\na = 2", 2),
            ("[t]\n[t]", 2),
            ("[[items]]", 1),
            ("a = \"\"\"multi\"\"\"", 1),
            ("a = 1979-05-27", 1),
            ("a = \"unterminated", 1),
            ("a = 1 b = 2", 1),
            ("a = 1\n[a]", 2),
            ("a = [1 2]", 1),
        ]
        for (toml, line) in cases {
            XCTAssertThrowsError(try TOMLParser.parse(toml), toml) { error in
                XCTAssertEqual((error as? TOMLParser.ParseError)?.line, line, toml)
            }
        }
    }

    func testMissingConfigFileIsEmpty() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString).toml")
        let config = try StaticConfigProvider(contentsOf: url)
        XCTAssertNil(config.value(forKeyPath: "general"))
    }

    func testConfigValueJSONRoundTrip() throws {
        let value: ConfigValue = ["s": "x", "i": 1, "d": 1.5, "b": true, "a": [false, 2]]
        let data = try JSONEncoder().encode(value)
        XCTAssertEqual(try JSONDecoder().decode(ConfigValue.self, from: data), value)
    }
}
