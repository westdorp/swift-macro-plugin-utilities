import SwiftSyntax

public func hasSendableConformance(
    in classDecl: ClassDeclSyntax,
    lexicalContext: [Syntax] = []
) -> Bool {
    if inheritedTypesContainSendable(classDecl.inheritanceClause?.inheritedTypes) {
        return true
    }

    let declaredTypeNameComponents = declaredTypeNameComponents(for: classDecl)

    if let sourceFile = sourceFile(containing: Syntax(classDecl)),
       syntaxContainsSendableExtension(
           in: Syntax(sourceFile),
           expectedTypeNameComponents: declaredTypeNameComponents
       )
    {
        return true
    }

    return lexicalContext.contains { contextNode in
        syntaxContainsSendableExtension(
            in: rootSyntax(containing: contextNode),
            expectedTypeNameComponents: declaredTypeNameComponents
        )
    }
}

public func sourceFile(containing node: Syntax) -> SourceFileSyntax? {
    var current = node
    while let parent = current.parent {
        current = parent
    }

    return current.as(SourceFileSyntax.self)
}

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

private func syntaxContainsSendableExtension(
    in syntax: Syntax,
    expectedTypeNameComponents: [String]
) -> Bool {
    if let extensionDecl = syntax.as(ExtensionDeclSyntax.self),
       let extendedTypeComponents = typeNameComponents(for: extensionDecl.extendedType),
       extendedTypeComponents == expectedTypeNameComponents,
       inheritedTypesContainSendable(extensionDecl.inheritanceClause?.inheritedTypes)
    {
        return true
    }

    return syntax.children(viewMode: .sourceAccurate).contains { child in
        syntaxContainsSendableExtension(
            in: child,
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

private func declaredTypeNameComponents(for classDecl: ClassDeclSyntax) -> [String] {
    var components: [String] = [classDecl.name.text]
    var current = Syntax(classDecl).parent

    while let node = current {
        if let name = nominalTypeName(from: node) {
            components.insert(name, at: 0)
        }
        current = node.parent
    }

    return components
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
