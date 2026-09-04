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
        organization.moveFolders(
            ["/work/school"],
            to: category.id,
            before: nil,
            knownFolderPaths: ["/work/school"]
        )

        let data = try JSONEncoder().encode(organization)
        let decoded = try JSONDecoder().decode(WorkspaceOrganization.self, from: data)

        XCTAssertEqual(decoded, organization)
        XCTAssertEqual(decoded.categoryID(forFolder: "/work/school"), category.id)
        XCTAssertEqual(decoded.folderOrder, ["/work/school"])
    }

    func testFoldersCanBeReorderedAndMovedAcrossCategories() throws {
        var organization = WorkspaceOrganization()
        let cloud = try XCTUnwrap(organization.addCategory(named: "cloud"))
        let web = try XCTUnwrap(organization.addCategory(named: "web"))
        let paths = [
            "/work/school",
            "/work/fashion-shop",
            "/work/center",
            "/work/ai",
            "/work/codex-util",
            "/work/webx"
        ]
        organization.assignFolders(Array(paths.prefix(5)), to: cloud.id)
        organization.assignFolders([paths[5]], to: web.id)

        organization.moveFolders(
            ["/work/codex-util"],
            to: cloud.id,
            before: "/work/fashion-shop",
            knownFolderPaths: paths
        )
        XCTAssertEqual(
            organization.orderedFolders(folders(paths: Array(paths.prefix(5)))).map(\.path),
            ["/work/school", "/work/codex-util", "/work/fashion-shop", "/work/center", "/work/ai"]
        )

        organization.moveFolders(
            ["/work/webx"],
            to: cloud.id,
            before: "/work/center",
            knownFolderPaths: paths
        )
        XCTAssertEqual(organization.categoryID(forFolder: "/work/webx"), cloud.id)
        XCTAssertEqual(
            organization.orderedFolders(folders(paths: paths)).map(\.path),
            ["/work/school", "/work/codex-util", "/work/fashion-shop", "/work/webx", "/work/center", "/work/ai"]
        )
    }

    func testCategoriesCanBeReorderedByDropTarget() throws {
        var organization = WorkspaceOrganization()
        let cloud = try XCTUnwrap(organization.addCategory(named: "cloud"))
        let webx = try XCTUnwrap(organization.addCategory(named: "webx"))
        let archive = try XCTUnwrap(organization.addCategory(named: "archive"))

        organization.moveCategory(id: archive.id, before: cloud.id)
        XCTAssertEqual(organization.categories.map(\.id), [archive.id, cloud.id, webx.id])

        organization.moveCategory(id: archive.id, before: webx.id)
        XCTAssertEqual(organization.categories.map(\.id), [cloud.id, archive.id, webx.id])

        organization.moveCategory(id: cloud.id, relativeTo: archive.id, placeAfter: true)
        XCTAssertEqual(organization.categories.map(\.id), [archive.id, cloud.id, webx.id])

        organization.moveCategoryToEnd(id: archive.id)
        XCTAssertEqual(organization.categories.map(\.id), [cloud.id, webx.id, archive.id])
    }

    func testLegacyOrganizationWithoutFolderOrderStillDecodes() throws {
        let data = try XCTUnwrap(
            """
            {"categories":[{"id":"cloud-id","name":"cloud"}],"folderAssignments":{"/work/school":"cloud-id"}}
            """.data(using: .utf8)
        )
        let decoded = try JSONDecoder().decode(WorkspaceOrganization.self, from: data)

        XCTAssertEqual(decoded.categories.map(\.name), ["cloud"])
        XCTAssertEqual(decoded.categoryID(forFolder: "/work/school"), "cloud-id")
        XCTAssertTrue(decoded.folderOrder.isEmpty)
    }

    private func folders(paths: [String]) -> [WorkspaceFolder] {
        paths.enumerated().map { index, path in
            WorkspaceFolder(
                path: path,
                threadCount: nil,
                latestUpdate: Date(timeIntervalSince1970: Double(paths.count - index))
            )
        }
    }
}
