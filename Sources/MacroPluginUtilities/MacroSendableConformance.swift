import SwiftSyntax
import SwiftSyntaxBuilder

/// Generates a `Sendable` extension for an eligible class that lacks visible conformance.
public func sendableExtensionIfNeeded(
    for type: some TypeSyntaxProtocol,
    attachedTo declaration: some DeclGroupSyntax,
    lexicalContext: [Syntax],
    when canGenerateMembers: (ClassDeclSyntax) -> Bool
) throws -> [ExtensionDeclSyntax] {
    guard let classDeclaration = declaration.as(ClassDeclSyntax.self),
          canGenerateMembers(classDeclaration),
          !hasSendableConformance(in: classDeclaration, lexicalContext: lexicalContext)
    else {
        return []
    }

    return [try ExtensionDeclSyntax("extension \(type): Sendable {}")]
}

/// Returns whether visible syntax gives a declaration group `Sendable` conformance.
///
/// The query checks direct inheritance and exactly qualified extensions in
/// source-file or declaration-group containers. For detached declarations,
/// lexical context supplies enclosing qualification and visible roots.
public func hasSendableConformance(
    in declaration: some DeclGroupSyntax,
    lexicalContext: [Syntax] = []
) -> Bool {
    if inheritedTypesContainSendable(declaration.inheritanceClause?.inheritedTypes) {
        return true
    }

    guard let declaredTypeNameComponents = declaredTypeNameComponents(
        for: declaration,
        lexicalContext: lexicalContext
    ) else {
        return false
    }

    if let sourceFile = sourceFile(containing: Syntax(declaration)),
       declarationContainerContainsSendableExtension(
           in: Syntax(sourceFile),
           expectedTypeNameComponents: declaredTypeNameComponents
       )
    {
        return true
    }

    return lexicalContext.contains { contextNode in
        declarationContainerContainsSendableExtension(
            in: rootSyntax(containing: contextNode),
            expectedTypeNameComponents: declaredTypeNameComponents
        )
    }
}

/// Returns the source-file root of an attached syntax node.
public func sourceFile(containing node: Syntax) -> SourceFileSyntax? {
    var current = node
    while let parent = current.parent {
        current = parent
    }

    return current.as(SourceFileSyntax.self)
}

/// Returns whether inherited-type syntax references `Sendable`.
public func inheritedTypesContainSendable(_ inheritedTypes: InheritedTypeListSyntax?) -> Bool {
    guard let inheritedTypes else {
        return false
    }

    return inheritedTypes.contains { inheritedType in
        typeReferencesSendable(inheritedType.type)
    }
}

private func typeReferencesSendable(_ type: TypeSyntax) -> Bool {
    if let attributedType = type.as(AttributedTypeSyntax.self) {
        return typeReferencesSendable(attributedType.baseType)
    }

    if let identifierType = type.as(IdentifierTypeSyntax.self) {
        return identifierType.name.text == "Sendable"
    }

    if let memberType = type.as(MemberTypeSyntax.self) {
        return memberType.name.text == "Sendable"
    }

    if let compositionType = type.as(CompositionTypeSyntax.self) {
        return compositionType.elements.contains { element in
            typeReferencesSendable(element.type)
        }
    }

    let normalized = type.trimmedDescription.filter { character in
        !character.isWhitespace
    }

    return normalized == "Sendable"
        || normalized == "@uncheckedSendable"
        || normalized.hasSuffix(".Sendable")
}

private func declarationContainerContainsSendableExtension(
    in syntax: Syntax,
    expectedTypeNameComponents: [String]
) -> Bool {
    if let sourceFile = syntax.as(SourceFileSyntax.self) {
        return sourceFile.statements.contains { item in
            guard let declaration = item.item.as(DeclSyntax.self) else {
                return false
            }
            return declarationContainsSendableExtension(
                declaration,
                expectedTypeNameComponents: expectedTypeNameComponents
            )
        }
    }

    guard let declarationGroup = syntax.asProtocol(DeclGroupSyntax.self) else {
        return false
    }

    return memberBlockContainsSendableExtension(
        declarationGroup.memberBlock,
        expectedTypeNameComponents: expectedTypeNameComponents
    )
}

private func declarationContainsSendableExtension(
    _ declaration: DeclSyntax,
    expectedTypeNameComponents: [String]
) -> Bool {
    if let extensionDecl = declaration.as(ExtensionDeclSyntax.self),
       let extendedTypeComponents = typeNameComponents(for: extensionDecl.extendedType),
       extendedTypeComponents == expectedTypeNameComponents,
       inheritedTypesContainSendable(extensionDecl.inheritanceClause?.inheritedTypes)
    {
        return true
    }

    guard let declarationGroup = declaration.asProtocol(DeclGroupSyntax.self) else {
        return false
    }

    return memberBlockContainsSendableExtension(
        declarationGroup.memberBlock,
        expectedTypeNameComponents: expectedTypeNameComponents
    )
}

private func memberBlockContainsSendableExtension(
    _ memberBlock: MemberBlockSyntax,
    expectedTypeNameComponents: [String]
) -> Bool {
    memberBlock.members.contains { member in
        declarationContainsSendableExtension(
            member.decl,
            expectedTypeNameComponents: expectedTypeNameComponents
        )
    }
}

private func rootSyntax(containing node: Syntax) -> Syntax {
    var current = node

    while let parent = current.parent {
        current = parent
    }

    return current
}

private func declaredTypeNameComponents(
    for declaration: some DeclGroupSyntax,
    lexicalContext: [Syntax]
) -> [String]? {
    let declarationSyntax = Syntax(declaration)

    if let extensionDecl = declarationSyntax.as(ExtensionDeclSyntax.self) {
        return typeNameComponents(for: extensionDecl.extendedType)
    }

    guard let declaredName = nominalTypeName(from: declarationSyntax) else {
        return nil
    }

    let enclosingComponents: [String]
    if let parent = declarationSyntax.parent {
        guard let attachedComponents = enclosingTypeNameComponents(startingAt: parent) else {
            return nil
        }
        enclosingComponents = attachedComponents
    } else {
        guard let lexicalComponents = enclosingTypeNameComponents(
            in: lexicalContext
        ) else {
            return nil
        }
        enclosingComponents = lexicalComponents
    }

    return enclosingComponents + [declaredName]
}

private func enclosingTypeNameComponents(startingAt syntax: Syntax) -> [String]? {
    var components: [String] = []
    var current: Syntax? = syntax

    while let node = current {
        guard let nodeComponents = enclosingTypeNameComponents(for: node) else {
            return nil
        }
        components.insert(contentsOf: nodeComponents, at: 0)
        current = node.parent
    }

    return components
}

private func enclosingTypeNameComponents(in lexicalContext: [Syntax]) -> [String]? {
    var components: [String] = []

    for node in lexicalContext {
        guard let nodeComponents = enclosingTypeNameComponents(for: node) else {
            return nil
        }
        components.insert(contentsOf: nodeComponents, at: 0)
    }

    return components
}

private func enclosingTypeNameComponents(for syntax: Syntax) -> [String]? {
    if let extensionDecl = syntax.as(ExtensionDeclSyntax.self) {
        return typeNameComponents(for: extensionDecl.extendedType)
    }

    if let name = nominalTypeName(from: syntax) {
        return [name]
    }

    return []
}

private func nominalTypeName(from syntax: Syntax) -> String? {
    if let classDecl = syntax.as(ClassDeclSyntax.self) {
        return classDecl.name.text
    }

    if let structDecl = syntax.as(StructDeclSyntax.self) {
        return structDecl.name.text
    }

    if let enumDecl = syntax.as(EnumDeclSyntax.self) {
        return enumDecl.name.text
    }

    if let actorDecl = syntax.as(ActorDeclSyntax.self) {
        return actorDecl.name.text
    }

    if let protocolDecl = syntax.as(ProtocolDeclSyntax.self) {
        return protocolDecl.name.text
    }

    return nil
}

private func typeNameComponents(for type: TypeSyntax) -> [String]? {
    if let attributedType = type.as(AttributedTypeSyntax.self) {
        return typeNameComponents(for: attributedType.baseType)
    }

    if let identifierType = type.as(IdentifierTypeSyntax.self) {
        return [identifierType.name.text]
    }

    if let memberType = type.as(MemberTypeSyntax.self),
       let baseTypeComponents = typeNameComponents(for: memberType.baseType)
    {
        return baseTypeComponents + [memberType.name.text]
    }

    return nil
}
