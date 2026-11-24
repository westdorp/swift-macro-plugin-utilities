import MacroPluginUtilities
import SwiftSyntax
import SwiftSyntaxMacros

public enum RequireFinalDiagnosticID: String, Sendable {
    case nonClassDeclaration = "non-class-declaration"
    case openClass = "open-class"
    case missingFinal = "missing-final"
}

public struct RequireFinalMacro: MemberMacro {
    public static let diagnosticDomain = "RequireFinalMacro"

    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) -> [DeclSyntax] {
        guard let classDecl = declaration.as(ClassDeclSyntax.self) else {
            context.diagnose(
                declaration,
                domain: diagnosticDomain,
                id: RequireFinalDiagnosticID.nonClassDeclaration,
                what: "@RequireFinal can only be applied to a class.",
                why: "Only classes can be subclassed and require a 'final' modifier.",
                how: "Remove @RequireFinal from this declaration or attach it to a class."
            )
            return []
        }

        if hasModifier(named: "open", in: classDecl.modifiers) {
            context.diagnose(
                classDecl.name,
                domain: diagnosticDomain,
                id: RequireFinalDiagnosticID.openClass,
                what: "@RequireFinal cannot be applied to an 'open' class.",
                why: "An 'open' class allows external subclassing, which conflicts with 'final'.",
                how: "Replace 'open' with 'public final', or remove @RequireFinal."
            )
            return []
        }

        guard !hasModifier(named: "final", in: classDecl.modifiers) else {
            return []
        }

        let fixIt = makeAddFinalFixIt(
            for: classDecl,
            fixItMessage: MacroFixItMessage("Add 'final' modifier", domain: diagnosticDomain)
        )
        context.diagnose(
            classDecl.name,
            domain: diagnosticDomain,
            id: RequireFinalDiagnosticID.missingFinal,
            what: "@RequireFinal requires a final class.",
            why: "Subclasses would bypass the type's invariants.",
            how: "Add the 'final' modifier to this class declaration.",
            fixIts: [fixIt]
        )
        return []
    }
}
