import MacroPluginUtilities
import SwiftSyntax
import SwiftSyntaxMacros

public enum RequireFinalDiagnosticID: String, Sendable {
    case nonClassDeclaration = "non-class-declaration"
    case openClass = "open-class"
    case openMembers = "open-members"
    case missingFinal = "missing-final"
}

public struct RequireFinalMacro: PeerMacro {
    public static let diagnosticDomain = "RequireFinalMacro"

    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
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
                how: "Replace 'open' with 'public final', change any 'open' members to 'public', or remove @RequireFinal."
            )
            return []
        }

        guard !hasModifier(named: "final", in: classDecl.modifiers) else {
            return []
        }

        if hasOpenMember(in: classDecl.memberBlock.members) {
            context.diagnose(
                classDecl.name,
                domain: diagnosticDomain,
                id: RequireFinalDiagnosticID.openMembers,
                what: "@RequireFinal requires a final class, but this class declares 'open' members.",
                why: "Swift forbids 'open' members on a 'final' class.",
                how: "Change the 'open' members to 'public' and add the 'final' modifier to this class declaration."
            )
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

private func hasOpenMember(in members: MemberBlockItemListSyntax) -> Bool {
    for member in members {
        if let ifConfig = member.decl.as(IfConfigDeclSyntax.self) {
            for clause in ifConfig.clauses {
                if case .decls(let conditionalMembers) = clause.elements,
                   hasOpenMember(in: conditionalMembers) {
                    return true
                }
            }
            continue
        }

        if member.decl.isProtocol(DeclGroupSyntax.self) {
            continue
        }

        if let modified = member.decl.asProtocol(WithModifiersSyntax.self),
           hasModifier(named: "open", in: modified.modifiers) {
            return true
        }
    }

    return false
}
