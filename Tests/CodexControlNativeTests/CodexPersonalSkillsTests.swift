import XCTest
@testable import CloudCodex

final class CodexPersonalSkillsTests: XCTestCase {
    func testListKeepsOnlyUserCreatedSkillsAndUsesInterfaceMetadata() throws {
        let personalRoot = "/Users/test/.agents/skills"
        let response: [String: Any] = [
            "data": [[
                "cwd": "/tmp/project",
                "skills": [
                    skill(
                        name: "plugin-skill",
                        description: "插件技能",
                        path: "/Users/test/.codex/plugins/cache/example/skills/plugin-skill/SKILL.md",
                        scope: "user"
                    ),
                    skill(
                        name: "hidden-system-skill",
                        description: "隐藏系统技能",
                        path: "/Users/test/.agents/skills/.system/hidden-system-skill/SKILL.md",
                        scope: "user"
                    ),
                    skill(
                        name: "my-review",
                        description: "完整说明",
                        path: "/Users/test/.agents/skills/my-review/SKILL.md",
                        scope: "user",
                        interface: [
                            "displayName": "我的审查技能",
                            "shortDescription": "检查改动边界"
                        ]
                    ),
                    skill(
                        name: "skill-creator",
                        description: "系统技能",
                        path: "/system/skill-creator/SKILL.md",
                        scope: "system"
                    ),
                    skill(
                        name: "repo-helper",
                        description: "仓库技能",
                        path: "/tmp/project/.agents/skills/repo-helper/SKILL.md",
                        scope: "repo"
                    )
                ],
                "errors": []
            ]]
        ]

        let skills = CodexPersonalSkill.parseListResponse(response, personalSkillRoots: [personalRoot])

        XCTAssertEqual(skills.count, 1)
        XCTAssertEqual(skills[0].name, "my-review")
        XCTAssertEqual(skills[0].title, "我的审查技能")
        XCTAssertEqual(skills[0].summary, "检查改动边界")
        XCTAssertTrue(skills[0].enabled)
    }

    func testListDeduplicatesRepeatedCwdResultsAndSortsByVisibleTitle() {
        let personalRoot = "/Users/test/.agents/skills"
        let alpha = skill(
            name: "alpha",
            description: "Alpha",
            path: "/Users/test/.agents/skills/alpha/SKILL.md",
            scope: "user"
        )
        let beta = skill(
            name: "beta",
            description: "Beta",
            path: "/Users/test/.agents/skills/beta/SKILL.md",
            scope: "user"
        )
        let response: [String: Any] = [
            "data": [
                ["cwd": "/tmp/a", "skills": [beta, alpha], "errors": []],
                ["cwd": "/tmp/b", "skills": [alpha], "errors": []]
            ]
        ]

        XCTAssertEqual(
            CodexPersonalSkill.parseListResponse(response, personalSkillRoots: [personalRoot]).map(\.name),
            ["alpha", "beta"]
        )
    }

    private func skill(
        name: String,
        description: String,
        path: String,
        scope: String,
        interface: [String: Any]? = nil
    ) -> [String: Any] {
        var value: [String: Any] = [
            "name": name,
            "description": description,
            "path": path,
            "scope": scope,
            "enabled": true
        ]
        if let interface { value["interface"] = interface }
        return value
    }
}
