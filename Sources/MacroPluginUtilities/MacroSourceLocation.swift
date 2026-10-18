import SwiftSyntax
import SwiftSyntaxMacros

/// A `#sourceLocation` directive that attributes the lines after it to `node`'s line in the
/// user's file, so a type error in generated code is reported on the user's declaration; `nil`
/// when the context cannot locate `node`.
///
/// Close the covered lines with `#sourceLocation()`.
///
/// - Parameter lineOffset: Added to the node's line, for an expansion that puts lines between
///   the directive and the code it covers.
public func sourceLocationDirective(
    at node: some SyntaxProtocol,
    lineOffset: Int = 0,
    in context: some MacroExpansionContext
) -> String? {
    guard let location = context.location(of: node, at: .afterLeadingTrivia, filePathMode: .filePath),
          let line = location.line.as(IntegerLiteralExprSyntax.self)?.representedLiteralValue
    else {
        return nil
    }
    return "#sourceLocation(file: \(location.file.trimmedDescription), line: \(line + lineOffset))"
}
