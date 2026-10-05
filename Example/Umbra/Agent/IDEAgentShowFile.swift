import AgentKit
import Foundation

/// Opens a project file in the editor. Read-only: Plan mode can use it, and it never changes the file.
struct IDEShowFileTool: AgentTool {
    let root: URL
    let box: IDEAgentHostBox

    var risk: ToolRisk { .read }
    var definition: ToolDefinition {
        ToolDefinition(
            name: "show_file",
            description: """
            Open a project file in the editor so the user can see it. Pass a project-relative path, \
            and a 1-based line when you want the caret there. This does not read or change the file; \
            use read_file to look at its text.
            """,
            parameters: [
                ToolParameter("path", .string, "Project-relative path of the file to open."),
                ToolParameter("line", .integer, "1-based line to put the caret on.", optional: true),
                ToolParameter("column", .integer, "1-based column on that line.", optional: true),
            ])
    }

    func run(_ arguments: ToolArguments, context: ToolContext) async throws -> String {
        let path = try arguments.string("path")
        let line = try arguments.optionalInt("line")
        let column = try arguments.optionalInt("column")
        if let line, line < 1 { throw ToolError("line must be 1 or greater.") }
        if let column, column < 1 { throw ToolError("column must be 1 or greater.") }

        let jail = PathJail(root: root)
        let url = try jail.resolve(path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw AgentWorkspaceError.notFound(path)
        }
        guard !isDirectory.boolValue else { throw AgentWorkspaceError.notAFile(path) }

        let relative = jail.relativePath(of: url)
        try await box.showFile(relativePath: relative, line: line, column: column)
        if let line {
            return "Opened \(relative) at line \(line)."
        }
        return "Opened \(relative)."
    }
}
