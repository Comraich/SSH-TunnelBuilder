import XCTest

final class SSHTunnelBuilderUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testSidebarSelectionAndDetailPresence() throws {
        let app = XCUIApplication()
        app.launch()

        // Look up views by accessibility identifiers set in the app.
        let sidebar = app.otherElements["NavigationList"]
        let detail = app.otherElements["MainView"]

        XCTAssertTrue(sidebar.waitForExistence(timeout: 5), "Expected NavigationList (sidebar) to exist")
        XCTAssertTrue(detail.waitForExistence(timeout: 5), "Expected MainView (detail) to exist")

        // Try to tap the first cell in the sidebar if available.
        // Sidebar may be a table or a collection; fall back to any cell descendant.
        let firstCell = app.cells.firstMatch
        if firstCell.waitForExistence(timeout: 2) {
            firstCell.tap()
        }

        // After selection, we expect the detail to still be present and visible.
        XCTAssertTrue(detail.exists, "Expected MainView to be present after selection")
    }
}

