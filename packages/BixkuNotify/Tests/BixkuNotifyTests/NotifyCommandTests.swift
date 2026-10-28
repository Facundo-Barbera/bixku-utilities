import BixkuDock
import Foundation
import XCTest
@testable import BixkuNotify

final class NotifyCommandTests: XCTestCase {
    func testBuildsURLFromOptions() throws {
        let command = try NotifyCommand.parse([
            "--title", "Deploy done", "--body", "all green", "--category", "build", "--app", "CI", "--print",
        ]).get()
        XCTAssertTrue(command.printOnly)
        let notification = try NotifyURL.parse(command.url).get()
        XCTAssertEqual(notification.title, "Deploy done")
        XCTAssertEqual(notification.body, "all green")
        XCTAssertEqual(notification.category, .build)
        XCTAssertEqual(notification.appName, "CI")
    }

    func testDefaultAppNameAndOpenByDefault() throws {
        let command = try NotifyCommand.parse(["--title", "Hi"]).get()
        XCTAssertFalse(command.printOnly)
        XCTAssertEqual(try NotifyURL.parse(command.url).get().appName, NotifyCommand.defaultApp)
    }

    func testUsageErrors() {
        XCTAssertEqual(NotifyCommand.parse([]), .failure(.invalidNotification(.missingTitle)))
        XCTAssertEqual(NotifyCommand.parse(["--title"]), .failure(.missingValue("--title")))
        XCTAssertEqual(NotifyCommand.parse(["--title", "x", "--nope"]), .failure(.unknownOption("--nope")))
        XCTAssertEqual(
            NotifyCommand.parse(["--title", "x", "--category", "loud"]), .failure(.invalidCategory("loud"))
        )
        XCTAssertEqual(NotifyCommand.parse(["-h"]), .failure(.helpRequested))
    }

    func testUsageListsEveryCategory() {
        for category in NotificationCategory.allCases {
            XCTAssertTrue(NotifyCommand.usage.contains(category.rawValue))
        }
    }
}
