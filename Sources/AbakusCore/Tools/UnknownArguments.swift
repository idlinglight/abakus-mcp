/// Unknown arguments are errors in every tool: a typo such as `amout` or `decimal_mark` would otherwise be
/// ignored, and the call would quietly do something other than what was asked. One wording for all tools, built
/// from the tool's input schema, so the list of arguments in the error is always the one the tool takes.
enum UnknownArguments {
    /// A sentence to add to the error for one particular unknown argument, chosen by the value passed (such as an
    /// argument that was removed and means different things depending on its value). nil adds nothing.
    typealias Hint = @Sendable (JSONValue) -> String?

    /// Throws for the first argument that `tool`'s input schema does not list under `properties`. The error
    /// names the arguments the tool takes, in schema order, with the required ones marked.
    static func refuse(_ arguments: JSONObject, for tool: some Tool, hints: [String: Hint] = [:]) throws(ToolError) {
        let schema = tool.inputSchema.objectValue
        let properties = schema?["properties"]?.objectValue?.keys ?? []
        guard let unknown = arguments.entries.first(where: { !properties.contains($0.key) }) else { return }
        let required = Set(schema?["required"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        let taken = properties.map { required.contains($0) ? "\($0.quotedForMessage) (required)" : $0.quotedForMessage }
        var message = "Unknown argument \(unknown.key.quotedForMessage). "
        message += taken.isEmpty ? "\(tool.name) takes no arguments." : "\(tool.name) takes \(taken.listedInProse)."
        if let hint = hints[unknown.key]?(unknown.value) {
            message += " " + hint
        }
        throw ToolError(message, details: ["argument": .string(unknown.key.cutForMessage)])
    }
}

extension [String] {
    /// The items as a list in a sentence, for messages: `a`, `a and b`, `a, b and c`.
    var listedInProse: String {
        guard let last, count > 1 else { return joined() }
        return dropLast().joined(separator: ", ") + " and " + last
    }
}
