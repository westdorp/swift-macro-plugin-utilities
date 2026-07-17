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

/// Creates a one-change fix-it that prepends `@MainActor` to the attributes.
public func makeAddMainActorFixIt(for classDecl: ClassDeclSyntax, fixItMessage: MacroFixItMessage) -> FixIt {
    let mainActorAttribute = AttributeSyntax(
        atSign: .atSignToken(),
        attributeName: IdentifierTypeSyntax(name: .identifier("MainActor")),
        trailingTrivia: .newlines(1)
    )
    let updatedAttributes = AttributeListSyntax(
        [.attribute(mainActorAttribute)] + Array(classDecl.attributes)
    )

    return FixIt(
        message: fixItMessage,
        changes: [
            .replace(oldNode: Syntax(classDecl.attributes), newNode: Syntax(updatedAttributes))
        ]
    )
}
