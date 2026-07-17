import SwiftSyntax

public func hasModifier(named name: String, in modifiers: DeclModifierListSyntax) -> Bool {
    modifiers.contains { modifier in
        modifier.name.text == name
    }
}

public func hasAttribute(named name: String, in attributes: AttributeListSyntax) -> Bool {
    attributes.contains { element in
        guard let attribute = element.as(AttributeSyntax.self) else {
            return false
        }

        return attributeNameMatches(attribute, expected: name)
    }
}

public func attributeNameMatches(_ attribute: AttributeSyntax, expected: String) -> Bool {
    let attributeName = attribute.attributeName.trimmedDescription
    return attributeName == expected || attributeName.hasSuffix(".\(expected)")
}

public func typeMatches(_ type: TypeSyntax, expectedTypeName: String) -> Bool {
    let normalized = normalizedTypeText(type)
    return normalized == expectedTypeName || normalized.hasSuffix(".\(expectedTypeName)")
}

/// Renders a type in the canonical spelling used by expected-type tables:
/// optionals as `?`, `any` markers dropped, single-element parentheses
/// unwrapped, whitespace removed.
private func normalizedTypeText(_ type: TypeSyntax) -> String {
    if let optionalType = type.as(OptionalTypeSyntax.self) {
        return normalizedTypeText(optionalType.wrappedType) + "?"
    }

    if let identifierType = type.as(IdentifierTypeSyntax.self),
       identifierType.name.text == "Optional",
       let arguments = identifierType.genericArgumentClause?.arguments,
       arguments.count == 1,
       let argument = arguments.first,
       case .type(let wrappedType) = argument.argument {
        return normalizedTypeText(wrappedType) + "?"
    }

    if let tupleType = type.as(TupleTypeSyntax.self),
       tupleType.elements.count == 1,
       let element = tupleType.elements.first,
       element.firstName == nil {
        return normalizedTypeText(element.type)
    }

    if let someOrAnyType = type.as(SomeOrAnyTypeSyntax.self),
       someOrAnyType.someOrAnySpecifier.tokenKind == .keyword(.any) {
        return normalizedTypeText(someOrAnyType.constraint)
    }

    return type.trimmedDescription.filter { character in
        !character.isWhitespace
    }
}

public func isInstanceVariable(_ variableDecl: VariableDeclSyntax) -> Bool {
    !variableDecl.modifiers.contains { modifier in
        let name = modifier.name.text
        return name == "static" || name == "class"
    }
}
