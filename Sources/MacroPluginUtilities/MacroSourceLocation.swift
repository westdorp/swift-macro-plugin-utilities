import SwiftSyntax
import SwiftSyntaxMacros

/// A `#sourceLocation` directive that attributes the lines after it to the line where `node`
/// starts, after its leading trivia, in the user's file, so a type error in generated code is
/// reported on the user's declaration.
///
/// Close the covered lines with `#sourceLocation()`.
///
/// Returns `nil` when no directive can name that place: the context can't locate `node`, the
/// file path holds a character a string literal must escape (a quote, backslash, tab, newline
/// or other control character; `#sourceLocation` reads its file literally, so an escaped path
/// names a different file), or `lineOffset` moves the line below 1.
///
/// - Parameter lineOffset: Added to the node's line, for an expansion that puts lines between
///   the directive and the code it covers.
public func sourceLocationDirective(
    at node: some SyntaxProtocol,
    lineOffset: Int = 0,
    in context: some MacroExpansionContext
) -> String? {
    guard let location = context.location(of: node, at: .afterLeadingTrivia, filePathMode: .filePath),
          let line = location.line.as(IntegerLiteralExprSyntax.self)?.representedLiteralValue,
          let file = location.file.as(StringLiteralExprSyntax.self),
          let path = file.representedLiteralValue,
          file.trimmedDescription == "\"\(path)\"",
          line + lineOffset >= 1
    else {
        return nil
    }
    return "#sourceLocation(file: \(file.trimmedDescription), line: \(line + lineOffset))"
}
