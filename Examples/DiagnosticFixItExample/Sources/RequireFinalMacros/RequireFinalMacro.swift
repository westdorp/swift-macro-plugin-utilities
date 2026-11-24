import MacroPluginUtilities
import SwiftSyntax
import SwiftSyntaxMacros

public enum RequireFinalDiagnosticID: String, Sendable {
    case nonClassDeclaration = "non-class-declaration"
    case openClass = "open-class"
    case openMembers = "open-members"
    case nestedClasses = "nested-classes"
    case missingFinal = "missing-final"
}

private enum RequireFinalValidation {
    case validFinalClass
    case nonClass
    case openClass(ClassDeclSyntax)
    case classWithOpenMembers(ClassDeclSyntax)
    case classWithNestedClasses(ClassDeclSyntax)
    case fixableNonFinalClass(ClassDeclSyntax)
}

public struct RequireFinalMacro: PeerMacro {
    public static let diagnosticDomain = "RequireFinalMacro"

    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) -> [DeclSyntax] {
        switch validate(declaration) {
        case .validFinalClass:
            return []
        case .nonClass:
            context.diagnose(
                declaration,
                domain: diagnosticDomain,
                id: RequireFinalDiagnosticID.nonClassDeclaration,
                what: "@RequireFinal can only be applied to a class.",
                why: "Only classes can be subclassed and require a 'final' modifier.",
                how: "Remove @RequireFinal from this declaration or attach it to a class."
            )
            return []
        case .openClass(let classDecl):
            context.diagnose(
                classDecl.name,
                domain: diagnosticDomain,
                id: RequireFinalDiagnosticID.openClass,
                what: "@RequireFinal cannot be applied to an 'open' class.",
                why: "An 'open' class allows external subclassing, which conflicts with 'final'.",
                how: "Replace 'open' with 'public final', change any 'open' members to 'public', or remove @RequireFinal."
            )
            return []
        case .classWithOpenMembers(let classDecl):
            context.diagnose(
                classDecl.name,
                domain: diagnosticDomain,
                id: RequireFinalDiagnosticID.openMembers,
                what: "@RequireFinal requires a final class, but this class contains 'open' member declarations.",
                why: "Swift forbids 'open' members on a 'final' class.",
                how: "Change any 'open' members to 'public' before adding 'final'."
            )
            return []
        case .classWithNestedClasses(let classDecl):
            context.diagnose(
                classDecl.name,
                domain: diagnosticDomain,
                id: RequireFinalDiagnosticID.nestedClasses,
                what: "@RequireFinal requires a final class, and omits the automatic fix-it when the class contains nested or local class declarations.",
                why: "Nested or local classes may subclass this class, which Swift forbids once 'final' is added.",
                how: "Review nested or local classes, update any subclassing, and add the 'final' modifier manually."
            )
            return []
        case .fixableNonFinalClass(let classDecl):
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
                how: "Confirm no external declaration subclasses this type, then add the 'final' modifier to this class declaration.",
                fixIts: [fixIt]
            )
            return []
        }
    }
}

private func validate(_ declaration: some DeclSyntaxProtocol) -> RequireFinalValidation {
    guard let classDecl = declaration.as(ClassDeclSyntax.self) else {
        return .nonClass
    }
    if hasModifier(named: "open", in: classDecl.modifiers) {
        return .openClass(classDecl)
    }
    if hasModifier(named: "final", in: classDecl.modifiers) {
        return .validFinalClass
    }
    if hasOpenMember(in: classDecl.memberBlock.members) {
        return .classWithOpenMembers(classDecl)
    }
    if hasNestedClass(in: classDecl.memberBlock) {
        return .classWithNestedClasses(classDecl)
    }
    return .fixableNonFinalClass(classDecl)
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

private func hasNestedClass(in memberBlock: MemberBlockSyntax) -> Bool {
    final class Finder: SyntaxVisitor {
        var found = false

        override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
            found = true
            return .skipChildren
        }
    }

    let finder = Finder(viewMode: .sourceAccurate)
    finder.walk(memberBlock)
    return finder.found
}
