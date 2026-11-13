import SwiftDiagnostics
import SwiftSyntax

/// Creates a one-change fix-it that inserts `final` without losing trivia.
public func makeAddFinalFixIt(for classDecl: ClassDeclSyntax, fixItMessage: MacroFixItMessage) -> FixIt {
    var updatedClassDecl = classDecl

    if classDecl.modifiers.isEmpty {
        var classKeyword = classDecl.classKeyword
        let classLeadingTrivia = classKeyword.leadingTrivia
        classKeyword.leadingTrivia = []
        updatedClassDecl.classKeyword = classKeyword

        let finalModifier = DeclModifierSyntax(
            leadingTrivia: classLeadingTrivia,
            name: .keyword(.final, trailingTrivia: .space)
        )
        updatedClassDecl.modifiers = DeclModifierListSyntax([finalModifier])
    } else {
        let finalModifier = DeclModifierSyntax(name: .keyword(.final, trailingTrivia: .space))
        updatedClassDecl.modifiers = DeclModifierListSyntax(
            Array(classDecl.modifiers) + [finalModifier]
        )
    }

    return FixIt(
        message: fixItMessage,
        changes: [
            .replace(oldNode: Syntax(classDecl), newNode: Syntax(updatedClassDecl))
        ]
    )
}

/// Creates a one-change fix-it that prepends `@MainActor` on its own line.
///
/// The attribute takes the declaration's leading trivia, so it stays on the
/// declaration's line; the rest of the declaration follows on a new line at the
/// same indentation.
public func makeAddMainActorFixIt(for classDecl: ClassDeclSyntax, fixItMessage: MacroFixItMessage) -> FixIt {
    let leadingTrivia = classDecl.leadingTrivia
    let mainActorAttribute = AttributeSyntax(
        leadingTrivia: leadingTrivia,
        atSign: .atSignToken(),
        attributeName: IdentifierTypeSyntax(name: .identifier("MainActor")),
        trailingTrivia: .newline + indentation(of: leadingTrivia)
    )
    var updatedClassDecl = classDecl.with(\.leadingTrivia, [])
    updatedClassDecl.attributes = AttributeListSyntax(
        [.attribute(mainActorAttribute)] + Array(updatedClassDecl.attributes)
    )

    return FixIt(
        message: fixItMessage,
        changes: [
            .replace(oldNode: Syntax(classDecl), newNode: Syntax(updatedClassDecl))
        ]
    )
}

/// The horizontal whitespace after the last newline in `trivia`.
private func indentation(of trivia: Trivia) -> Trivia {
    var pieces: [TriviaPiece] = []
    for piece in trivia.pieces.reversed() {
        switch piece {
        case .spaces, .tabs:
            pieces.insert(piece, at: 0)
        default:
            return Trivia(pieces: pieces)
        }
    }
    return Trivia(pieces: pieces)
}

/// Creates a one-change fix-it that removes a property's inline initializer.
public func makeRemoveInitializerFixIt(
    from property: InlineInitializedStoredProperty,
    propertyName: String,
    domain: String
) -> FixIt {
    var replacement = property.binding
    var trailingTriviaPieces = replacement.trailingTrivia.pieces
    replacement.initializer = nil
    trimHorizontalWhitespace: while let last = trailingTriviaPieces.last {
        switch last {
        case .spaces, .tabs:
            trailingTriviaPieces.removeLast()
        default:
            break trimHorizontalWhitespace
        }
    }
    replacement.trailingTrivia = Trivia(pieces: trailingTriviaPieces)

    return FixIt(
        message: MacroFixItMessage("Remove '\(propertyName)' initializer", domain: domain),
        changes: [
            .replace(oldNode: Syntax(property.binding), newNode: Syntax(replacement))
        ]
    )
}
