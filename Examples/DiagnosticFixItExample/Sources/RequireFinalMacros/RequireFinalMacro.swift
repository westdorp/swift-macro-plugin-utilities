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

        if hasVisibleNestedSubclass(in: classDecl, context: context) {
            let className = unescapedIdentifier(classDecl.name.text)
            context.diagnose(
                classDecl.name,
                domain: diagnosticDomain,
                id: RequireFinalDiagnosticID.nestedSubclass,
                what: "@RequireFinal requires a final class, but this class has a nested subclass.",
                why: "Swift forbids subclassing a 'final' class.",
                how: "Remove inheritance from '\(className)' on nested subclasses and add the 'final' modifier to this class declaration."
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
    context: some MacroExpansionContext
) -> Bool {
    let attachedName = unescapedIdentifier(classDecl.name.text)
    var candidatePaths: [[String]]
    if let enclosing = enclosingNominalPath(
        for: classDecl,
        lexicalContext: context.lexicalContext
    ) {
        let attachedPath = enclosing + [attachedName]
        candidatePaths = [attachedPath]
        if let module = moduleName(for: classDecl, in: context) {
            candidatePaths.append([module] + attachedPath)
        }
    } else {
        candidatePaths = [[attachedName]]
    }

    let finder = NestedSubclassFinder(
        candidatePaths: candidatePaths,
        rootMemberBlock: classDecl.memberBlock
    )
    finder.walk(classDecl.memberBlock)
    return finder.found
}

private final class NestedSubclassFinder: SyntaxVisitor {
    let candidatePaths: [[String]]
    let rootMemberBlock: MemberBlockSyntax
    var found = false

    init(candidatePaths: [[String]], rootMemberBlock: MemberBlockSyntax) {
        self.candidatePaths = candidatePaths
        self.rootMemberBlock = rootMemberBlock
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        if let inheritedTypes = node.inheritanceClause?.inheritedTypes,
           inheritedTypes.contains(where: {
               matchesAttachedClass(
                   $0.type,
                   from: node,
                   rootMemberBlock: rootMemberBlock,
                   candidatePaths: candidatePaths
               )
           }) {
            found = true
            return .skipChildren
        }
        return found ? .skipChildren : .visitChildren
    }
}

private func matchesAttachedClass(
    _ type: TypeSyntax,
    from childClass: ClassDeclSyntax,
    rootMemberBlock: MemberBlockSyntax,
    candidatePaths: [[String]]
) -> Bool {
    guard let components = nominalPathComponents(for: type),
          let leadingName = components.first,
          candidatePaths.contains(where: { path in
              components.count <= path.count
                  && Array(path.suffix(components.count)) == components
          })
    else {
        return false
    }

    return !isLeadingNameShadowed(
        leadingName,
        from: childClass,
        through: rootMemberBlock
    )
}

private func isLeadingNameShadowed(
    _ name: String,
    from childClass: ClassDeclSyntax,
    through rootMemberBlock: MemberBlockSyntax
) -> Bool {
    let childDecl = DeclSyntax(childClass)
    var current = Syntax(childClass).parent

    while let node = current {
        if let memberList = node.as(MemberBlockItemListSyntax.self),
           memberList.contains(where: {
               $0.decl != childDecl && declaredTypeName(of: $0.decl) == name
           }) {
            return true
        }
        if let statementList = node.as(CodeBlockItemListSyntax.self),
           statementList.contains(where: {
               guard case .decl(let decl) = $0.item else {
                   return false
               }
               return decl != childDecl && declaredTypeName(of: decl) == name
           }) {
            return true
        }
        if node == Syntax(rootMemberBlock) {
            break
        }
        current = node.parent
    }
    return false
}

private func declaredTypeName(of decl: DeclSyntax) -> String? {
    if let classDecl = decl.as(ClassDeclSyntax.self) {
        return unescapedIdentifier(classDecl.name.text)
    }
    if let structDecl = decl.as(StructDeclSyntax.self) {
        return unescapedIdentifier(structDecl.name.text)
    }
    if let enumDecl = decl.as(EnumDeclSyntax.self) {
        return unescapedIdentifier(enumDecl.name.text)
    }
    if let actorDecl = decl.as(ActorDeclSyntax.self) {
        return unescapedIdentifier(actorDecl.name.text)
    }
    if let protocolDecl = decl.as(ProtocolDeclSyntax.self) {
        return unescapedIdentifier(protocolDecl.name.text)
    }
    if let typeAliasDecl = decl.as(TypeAliasDeclSyntax.self) {
        return unescapedIdentifier(typeAliasDecl.name.text)
    }
    return nil
}

private func unescapedIdentifier(_ text: String) -> String {
    if text.count >= 2, text.first == "`", text.last == "`" {
        return String(text.dropFirst().dropLast())
    }
    return text
}

private func moduleName(
    for classDecl: ClassDeclSyntax,
    in context: some MacroExpansionContext
) -> String? {
    guard let location = context.location(
        of: classDecl,
        at: .afterLeadingTrivia,
        filePathMode: .fileID
    ),
    let stringLiteral = location.file.as(StringLiteralExprSyntax.self),
    let represented = stringLiteral.representedLiteralValue,
    let slash = represented.firstIndex(of: "/"),
    slash > represented.startIndex
    else {
        return nil
    }
    return String(represented[..<slash])
}

private func enclosingNominalPath(
    for classDecl: ClassDeclSyntax,
    lexicalContext: [Syntax]
) -> [String]? {
    var components: [String] = []
    if let parent = Syntax(classDecl).parent {
        var current: Syntax? = parent
        while let node = current {
            if isLocalScopeBoundary(node) {
                return nil
            }
            components.insert(contentsOf: enclosingComponents(for: node), at: 0)
            current = node.parent
        }
    } else {
        for node in lexicalContext {
            if isLocalScopeBoundary(node) {
                return nil
            }
            components.insert(contentsOf: enclosingComponents(for: node), at: 0)
        }
    }
    return components
}

private func isLocalScopeBoundary(_ syntax: Syntax) -> Bool {
    syntax.is(FunctionDeclSyntax.self)
        || syntax.is(InitializerDeclSyntax.self)
        || syntax.is(SubscriptDeclSyntax.self)
        || syntax.is(AccessorDeclSyntax.self)
        || syntax.is(DeinitializerDeclSyntax.self)
        || syntax.is(ClosureExprSyntax.self)
        || syntax.is(CodeBlockSyntax.self)
}

private func enclosingComponents(for syntax: Syntax) -> [String] {
    if let extensionDecl = syntax.as(ExtensionDeclSyntax.self) {
        return nominalPathComponents(for: extensionDecl.extendedType) ?? []
    }
    if let decl = syntax.as(DeclSyntax.self),
       let name = declaredTypeName(of: decl) {
        return [name]
    }
    return []
}

private func nominalPathComponents(for type: TypeSyntax) -> [String]? {
    if let tuple = type.as(TupleTypeSyntax.self),
       tuple.elements.count == 1,
       let element = tuple.elements.first,
       element.firstName == nil {
        return nominalPathComponents(for: element.type)
    }
    if let identifier = type.as(IdentifierTypeSyntax.self) {
        return [unescapedIdentifier(identifier.name.text)]
    }
    if let member = type.as(MemberTypeSyntax.self),
       let baseComponents = nominalPathComponents(for: member.baseType) {
        return baseComponents + [unescapedIdentifier(member.name.text)]
    }
    return nil
}
