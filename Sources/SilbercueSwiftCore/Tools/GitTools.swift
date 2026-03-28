import Foundation
import MCP

enum GitTools {
    static let tools: [Tool] = [
        Tool(
            name: "git_status",
            description: "Show git status (porcelain format) for a repository.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object(["type": .string("string"), "description": .string("Repository path")]),
                ]),
                "required": .array([.string("path")]),
            ])
        ),
        Tool(
            name: "git_diff",
            description: "Show git diff for a repository. Optionally diff staged changes or specific files.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object(["type": .string("string"), "description": .string("Repository path")]),
                    "staged": .object(["type": .string("boolean"), "description": .string("Show staged changes only. Default: false")]),
                    "file": .object(["type": .string("string"), "description": .string("Optional specific file to diff")]),
                ]),
                "required": .array([.string("path")]),
            ])
        ),
        Tool(
            name: "git_log",
            description: "Show recent git log entries.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object(["type": .string("string"), "description": .string("Repository path")]),
                    "count": .object(["type": .string("number"), "description": .string("Number of commits to show. Default: 10")]),
                    "oneline": .object(["type": .string("boolean"), "description": .string("One-line format. Default: true")]),
                ]),
                "required": .array([.string("path")]),
            ])
        ),
        Tool(
            name: "git_commit",
            description: "Create a git commit with staged changes.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object(["type": .string("string"), "description": .string("Repository path")]),
                    "message": .object(["type": .string("string"), "description": .string("Commit message")]),
                    "add_all": .object(["type": .string("boolean"), "description": .string("Stage all changes before committing. Default: false")]),
                ]),
                "required": .array([.string("path"), .string("message")]),
            ])
        ),
        Tool(
            name: "git_branch",
            description: "List, create, or switch git branches.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object(["type": .string("string"), "description": .string("Repository path")]),
                    "action": .object(["type": .string("string"), "description": .string("Action: list, create, switch. Default: list")]),
                    "name": .object(["type": .string("string"), "description": .string("Branch name (for create/switch)")]),
                ]),
                "required": .array([.string("path")]),
            ])
        ),
    ]

    // MARK: - Implementations

    static func gitStatus(_ args: [String: Value]?) async -> CallTool.Result {
        guard let path = args?["path"]?.stringValue else {
            return .fail("Missing required: path")
        }
        do {
            let result = try await Shell.git(["status", "--porcelain"], workingDirectory: path)
            if result.stdout.isEmpty {
                return .ok("Working tree clean")
            }
            return .ok(result.stdout)
        } catch {
            return .fail("Error: \(error)")
        }
    }

    static func gitDiff(_ args: [String: Value]?) async -> CallTool.Result {
        guard let path = args?["path"]?.stringValue else {
            return .fail("Missing required: path")
        }
        let staged = args?["staged"]?.boolValue ?? false
        let file = args?["file"]?.stringValue

        var gitArgs = ["diff"]
        if staged { gitArgs.append("--cached") }
        if let f = file { gitArgs.append(f) }

        do {
            let result = try await Shell.git(gitArgs, workingDirectory: path)
            if result.stdout.isEmpty {
                return .ok("No differences")
            }
            let output = result.stdout.count > 50000 ? String(result.stdout.prefix(50000)) + "\n... [truncated]" : result.stdout
            return .ok(output)
        } catch {
            return .fail("Error: \(error)")
        }
    }

    static func gitLog(_ args: [String: Value]?) async -> CallTool.Result {
        guard let path = args?["path"]?.stringValue else {
            return .fail("Missing required: path")
        }
        let count = args?["count"]?.intValue ?? 10
        let oneline = args?["oneline"]?.boolValue ?? true

        var gitArgs = ["log", "-\(count)"]
        if oneline {
            gitArgs.append("--oneline")
        } else {
            gitArgs += ["--format=%H%n%an <%ae>%n%ai%n%s%n"]
        }

        do {
            let result = try await Shell.git(gitArgs, workingDirectory: path)
            return .ok(result.stdout.isEmpty ? "No commits" : result.stdout)
        } catch {
            return .fail("Error: \(error)")
        }
    }

    static func gitCommit(_ args: [String: Value]?) async -> CallTool.Result {
        guard let path = args?["path"]?.stringValue,
              let message = args?["message"]?.stringValue else {
            return .fail("Missing required: path, message")
        }
        let addAll = args?["add_all"]?.boolValue ?? false

        do {
            if addAll {
                let addResult = try await Shell.git(["add", "-A"], workingDirectory: path)
                if !addResult.succeeded {
                    return .fail("git add failed: \(addResult.stderr)")
                }
            }

            let result = try await Shell.git(["commit", "-m", message], workingDirectory: path)
            if result.succeeded {
                return .ok("Committed: \(result.stdout)")
            }
            return .fail("Commit failed: \(result.stderr)")
        } catch {
            return .fail("Error: \(error)")
        }
    }

    static func gitBranch(_ args: [String: Value]?) async -> CallTool.Result {
        guard let path = args?["path"]?.stringValue else {
            return .fail("Missing required: path")
        }
        let action = args?["action"]?.stringValue ?? "list"
        let name = args?["name"]?.stringValue

        do {
            switch action {
            case "list":
                let result = try await Shell.git(["branch", "-a"], workingDirectory: path)
                return .ok(result.stdout.isEmpty ? "No branches" : result.stdout)

            case "create":
                guard let n = name else { return .fail("Missing branch name") }
                let result = try await Shell.git(["checkout", "-b", n], workingDirectory: path)
                return result.succeeded ? .ok("Created and switched to branch '\(n)'") : .fail(result.stderr)

            case "switch":
                guard let n = name else { return .fail("Missing branch name") }
                let result = try await Shell.git(["checkout", n], workingDirectory: path)
                return result.succeeded ? .ok("Switched to branch '\(n)'") : .fail(result.stderr)

            default:
                return .fail("Unknown action: \(action). Use: list, create, switch")
            }
        } catch {
            return .fail("Error: \(error)")
        }
    }
}
