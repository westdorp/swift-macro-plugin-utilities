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
    case openClass(ClassDeclSyntax, alreadyFinal: Bool)
    case finalClassWithOpenMembers(ClassDeclSyntax, hasNestedClasses: Bool)
    case nonFinalClassWithOpenMembers(ClassDeclSyntax, hasNestedClasses: Bool)
    case classWithNestedClasses(ClassDeclSyntax)
    case fixableNonFinalClass(ClassDeclSyntax)
}

private enum OpenMemberPresence {
    case none
    case conditionalOnly
    case unconditional
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
        case .openClass(let classDecl, let alreadyFinal):
            let replacement = alreadyFinal ? "public" : "public final"
            let removal = alreadyFinal ? "remove both 'final' and @RequireFinal" : "remove @RequireFinal"
            context.diagnose(
                classDecl.name,
                domain: diagnosticDomain,
                id: RequireFinalDiagnosticID.openClass,
                what: "@RequireFinal cannot be applied to an 'open' class.",
                why: "An 'open' class allows external subclassing, which conflicts with 'final'.",
                how: "Replace 'open' with '\(replacement)', change any 'open' members to 'public', update or remove any subclasses, or \(removal)."
            )
            return []
        case .finalClassWithOpenMembers(let classDecl, let hasNestedClasses):
            let how = hasNestedClasses
                ? "Change any 'open' members to 'public', review nested or local classes, and update any subclassing so they are valid on a 'final' class."
                : "Change any 'open' members to 'public' so they are valid on a 'final' class."
            context.diagnose(
                classDecl.name,
                domain: diagnosticDomain,
                id: RequireFinalDiagnosticID.openMembers,
                what: "@RequireFinal cannot accept a 'final' class that contains 'open' member declarations.",
                why: "Swift forbids 'open' members on a 'final' class.",
                how: how
            )
            return []
        case .nonFinalClassWithOpenMembers(let classDecl, let hasNestedClasses):
            let how = hasNestedClasses
                ? "Change any 'open' members to 'public', review nested or local classes and update any subclassing, and add the 'final' modifier manually."
                : "Change any 'open' members to 'public' before adding 'final'."
            context.diagnose(
                classDecl.name,
                domain: diagnosticDomain,
                id: RequireFinalDiagnosticID.openMembers,
                what: "@RequireFinal requires a final class, but this class contains 'open' member declarations.",
                why: "Swift forbids 'open' members on a 'final' class.",
                how: how
            )
            return []
        case .classWithNestedClasses(let classDecl):
            context.diagnose(
                classDecl.name,
                domain: diagnosticDomain,
                id: RequireFinalDiagnosticID.nestedClasses,
                what: "@RequireFinal can only be applied to a final class, and omits the automatic fix-it when the class contains nested or local class declarations.",
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
                what: "@RequireFinal can only be applied to a final class.",
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
    let isFinal = hasModifier(named: "final", in: classDecl.modifiers)
    if hasModifier(named: "open", in: classDecl.modifiers) {
        return .openClass(classDecl, alreadyFinal: isFinal)
    }

    let openMembers = openMemberPresence(in: classDecl.memberBlock.members)
    if isFinal {
        switch openMembers {
        case .unconditional:
            return .finalClassWithOpenMembers(
                classDecl,
                hasNestedClasses: hasNestedClass(in: classDecl.memberBlock)
            )
        case .none, .conditionalOnly:
            return .validFinalClass
        }
    }

    let hasNested = hasNestedClass(in: classDecl.memberBlock)
    switch openMembers {
    case .unconditional, .conditionalOnly:
        return .nonFinalClassWithOpenMembers(classDecl, hasNestedClasses: hasNested)
    case .none:
        return hasNested ? .classWithNestedClasses(classDecl) : .fixableNonFinalClass(classDecl)
    }
}

private func openMemberPresence(in members: MemberBlockItemListSyntax) -> OpenMemberPresence {
    var sawConditionalOpenMember = false

    for member in members {
        if let ifConfig = member.decl.as(IfConfigDeclSyntax.self) {
            if hasAnyOpenMember(in: ifConfig) {
                sawConditionalOpenMember = true
            }
            continue
        }

        if member.decl.isProtocol(DeclGroupSyntax.self) {
            continue
        }

        if let modified = member.decl.asProtocol(WithModifiersSyntax.self),
           hasModifier(named: "open", in: modified.modifiers) {
            return .unconditional
        }
    }

    return sawConditionalOpenMember ? .conditionalOnly : .none
}

private func hasAnyOpenMember(in ifConfig: IfConfigDeclSyntax) -> Bool {
    for clause in ifConfig.clauses {
        guard case .decls(let conditionalMembers) = clause.elements else {
            continue
        }
        if openMemberPresence(in: conditionalMembers) != .none {
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
