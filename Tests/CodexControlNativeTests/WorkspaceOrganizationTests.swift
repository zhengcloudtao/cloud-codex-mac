import XCTest
@testable import CloudCodex

final class WorkspaceOrganizationTests: XCTestCase {
    func testAssignMoveAndDeleteCategory() throws {
        var organization = WorkspaceOrganization()
        let development = try XCTUnwrap(organization.addCategory(named: "开发"))
        let study = try XCTUnwrap(organization.addCategory(named: "学习"))

        organization.assignFolders(["/work/ai", "/work/webx"], to: development.id)
        XCTAssertEqual(organization.categoryID(forFolder: "/work/ai"), development.id)
        XCTAssertEqual(organization.categoryID(forFolder: "/work/webx"), development.id)

        organization.assignFolders(["/work/ai"], to: study.id)
        XCTAssertEqual(organization.categoryID(forFolder: "/work/ai"), study.id)

        organization.assignFolders(["/work/ai"], to: nil)
        XCTAssertNil(organization.categoryID(forFolder: "/work/ai"))

        organization.deleteCategory(id: development.id)
        XCTAssertNil(organization.categoryID(forFolder: "/work/webx"))
    }

    func testNamesAreTrimmedAndCaseInsensitiveUnique() throws {
        var organization = WorkspaceOrganization()
        let category = try XCTUnwrap(organization.addCategory(named: "  开发  "))

        XCTAssertEqual(category.name, "开发")
        XCTAssertNil(organization.addCategory(named: "开发"))
        XCTAssertFalse(organization.renameCategory(id: category.id, to: "  "))

        _ = try XCTUnwrap(organization.addCategory(named: "Study"))
        XCTAssertFalse(organization.renameCategory(id: category.id, to: "study"))
    }

    func testOrganizationRoundTripsThroughJSON() throws {
        var organization = WorkspaceOrganization()
        let category = try XCTUnwrap(organization.addCategory(named: "常用项目"))
        organization.assignFolders(["/work/school"], to: category.id)

        let data = try JSONEncoder().encode(organization)
        let decoded = try JSONDecoder().decode(WorkspaceOrganization.self, from: data)

        XCTAssertEqual(decoded, organization)
        XCTAssertEqual(decoded.categoryID(forFolder: "/work/school"), category.id)
    }
}
