import XCTest
@testable import BixkuLLM

final class JSONValueTests: XCTestCase {
    func testLiteralsAndAccessors() {
        let v: JSONValue = ["a": 1, "b": [true, nil, "s"], "c": 1.5]
        XCTAssertEqual(v["a"]?.intValue, 1)
        XCTAssertEqual(v["c"]?.doubleValue, 1.5)
        XCTAssertEqual(v["c"]?.intValue, nil)
        XCTAssertEqual(v["b"]?[0]?.boolValue, true)
        XCTAssertEqual(v["b"]?[1], .null)
        XCTAssertEqual(v["b"]?[2]?.stringValue, "s")
        XCTAssertNil(v["missing"])
    }

    func testRoundTrip() throws {
        let text = #"{"x":[1,2.5,"y",null,false],"z":{"k":"v"}}"#
        let v = try JSONValue(jsonString: text)
        XCTAssertEqual(v.jsonString(), text)
    }

    func testDecodeIntoStruct() throws {
        struct P: Codable, Equatable { var name: String; var n: Int }
        let v = try JSONValue(encoding: P(name: "a", n: 3))
        XCTAssertEqual(try v.decode(P.self), P(name: "a", n: 3))
    }
}
