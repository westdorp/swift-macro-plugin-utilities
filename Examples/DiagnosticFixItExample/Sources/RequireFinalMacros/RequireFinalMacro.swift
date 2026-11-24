import MacroPluginUtilities
import SwiftSyntax
import SwiftSyntaxMacros

public enum RequireFinalDiagnosticID: String, Sendable {
    case nonClassDeclaration = "non-class-declaration"
    case openClass = "open-class"
    case openMembers = "open-members"
    case nestedSubclass = "nested-subclass"
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

        if hasVisibleNestedSubclass(
            in: classDecl,
            lexicalContext: context.lexicalContext
        ) {
            context.diagnose(
                classDecl.name,
                domain: diagnosticDomain,
                id: RequireFinalDiagnosticID.nestedSubclass,
                what: "@RequireFinal requires a final class, but this class has a nested subclass.",
                why: "Swift forbids subclassing a 'final' class.",
                how: "Remove inheritance from '\(classDecl.name.text)' on nested subclasses and add the 'final' modifier to this class declaration."
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

private func hasVisibleNestedSubclass(
    in classDecl: ClassDeclSyntax,
    lexicalContext: [Syntax]
) -> Bool {
    let attachedPath = enclosingTypeComponents(
        for: classDecl,
        lexicalContext: lexicalContext
    ) + [classDecl.name.text]
    let finder = NestedSubclassFinder(attachedPath: attachedPath)
    finder.walk(classDecl.memberBlock)
    return finder.found
}

private final class NestedSubclassFinder: SyntaxVisitor {
    let attachedPath: [String]
    var found = false

    init(attachedPath: [String]) {
        self.attachedPath = attachedPath
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        if let inheritedTypes = node.inheritanceClause?.inheritedTypes,
           inheritedTypes.contains(where: { matchesAttachedPath($0.type, attachedPath: attachedPath) }) {
            found = true
            return .skipChildren
        }
        return found ? .skipChildren : .visitChildren
    }
}

private func matchesAttachedPath(_ type: TypeSyntax, attachedPath: [String]) -> Bool {
    guard let components = nominalPathComponents(for: type),
          !components.isEmpty,
          components.count <= attachedPath.count
    else {
        return false
    }
    return Array(attachedPath.suffix(components.count)) == components
}

private func enclosingTypeComponents(
    for classDecl: ClassDeclSyntax,
    lexicalContext: [Syntax]
) -> [String] {
    var components: [String] = []
    if let parent = Syntax(classDecl).parent {
        var current: Syntax? = parent
        while let node = current {
            components.insert(contentsOf: enclosingComponents(for: node), at: 0)
            current = node.parent
        }
    } else {
        for node in lexicalContext {
            components.insert(contentsOf: enclosingComponents(for: node), at: 0)
        }
    }
    return components
}

private func enclosingComponents(for syntax: Syntax) -> [String] {
    if let extensionDecl = syntax.as(ExtensionDeclSyntax.self) {
        return nominalPathComponents(for: extensionDecl.extendedType) ?? []
    }
    if let classDecl = syntax.as(ClassDeclSyntax.self) {
        return [classDecl.name.text]
    }
    if let structDecl = syntax.as(StructDeclSyntax.self) {
        return [structDecl.name.text]
    }
    if let enumDecl = syntax.as(EnumDeclSyntax.self) {
        return [enumDecl.name.text]
    }
    if let actorDecl = syntax.as(ActorDeclSyntax.self) {
        return [actorDecl.name.text]
    }
    if let protocolDecl = syntax.as(ProtocolDeclSyntax.self) {
        return [protocolDecl.name.text]
    }
    return []
}

private func nominalPathComponents(for type: TypeSyntax) -> [String]? {
    if let identifier = type.as(IdentifierTypeSyntax.self) {
        return [identifier.name.text]
    }
    if let member = type.as(MemberTypeSyntax.self),
       let baseComponents = nominalPathComponents(for: member.baseType) {
        return baseComponents + [member.name.text]
    }
    return nil
}
