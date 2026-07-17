import SwiftSyntax

/// Returns whether a modifier list contains the exact modifier token text.
public func hasModifier(named name: String, in modifiers: DeclModifierListSyntax) -> Bool {
    modifiers.contains { modifier in
        modifier.name.text == name
    }
}

/// Returns whether an attribute has the expected unqualified or qualified name.
public func hasAttribute(named name: String, in attributes: AttributeListSyntax) -> Bool {
    attributes.contains { element in
        guard let attribute = element.as(AttributeSyntax.self) else {
            return false
        }

        return attributeNameMatches(attribute, expected: name)
    }
}

/// Matches an attribute's complete spelling or final qualified component.
public func attributeNameMatches(_ attribute: AttributeSyntax, expected: String) -> Bool {
    let attributeName = attribute.attributeName.trimmedDescription
    return attributeName == expected || attributeName.hasSuffix(".\(expected)")
}

/// Matches normalized type syntax against an exact or module-qualified name.
public func typeMatches(_ type: TypeSyntax, expectedTypeName: String) -> Bool {
    let normalized = normalizedTypeText(type)
    return normalized == expectedTypeName || normalized.hasSuffix(".\(expectedTypeName)")
}

/// Renders a type in the canonical spelling used by expected-type tables:
/// optionals as `?`, `any` markers dropped, single-element parentheses
/// unwrapped, whitespace removed. `some` remains distinct because opaque
/// types are not existential spellings.
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

/// Returns whether a variable declaration is an instance property.
public func isInstanceVariable(_ variableDecl: VariableDeclSyntax) -> Bool {
    !variableDecl.modifiers.contains { modifier in
        let name = modifier.name.text
        return name == "static" || name == "class"
    }
}

/// Returns names declared directly in a declaration group's member namespace.
public func existingMemberNames(in declaration: some DeclGroupSyntax) -> Set<String> {
    var names: Set<String> = []

    for member in declaration.memberBlock.members {
        if let variableDecl = member.decl.as(VariableDeclSyntax.self) {
            for binding in variableDecl.bindings {
                if let identifier = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text {
                    names.insert(identifier)
                }
            }
            continue
        }

        if let functionDecl = member.decl.as(FunctionDeclSyntax.self) {
            names.insert(functionDecl.name.text)
            continue
        }

        if let enumCaseDecl = member.decl.as(EnumCaseDeclSyntax.self) {
            for element in enumCaseDecl.elements {
                names.insert(element.name.text)
            }
            continue
        }

        if let nestedEnum = member.decl.as(EnumDeclSyntax.self) {
            names.insert(nestedEnum.name.text)
            continue
        }

        if let nestedStruct = member.decl.as(StructDeclSyntax.self) {
            names.insert(nestedStruct.name.text)
            continue
        }

        if let nestedClass = member.decl.as(ClassDeclSyntax.self) {
            names.insert(nestedClass.name.text)
            continue
        }

        if let nestedActor = member.decl.as(ActorDeclSyntax.self) {
            names.insert(nestedActor.name.text)
            continue
        }

        if let nestedProtocol = member.decl.as(ProtocolDeclSyntax.self) {
            names.insert(nestedProtocol.name.text)
            continue
        }

        if let typeAliasDecl = member.decl.as(TypeAliasDeclSyntax.self) {
            names.insert(typeAliasDecl.name.text)
        }
    }

    return names
}

/// Renders an enum-case pattern with caller-defined payload patterns.
public func renderEnumCasePattern(
    for element: EnumCaseElementSyntax,
    payloadPattern: (_ parameterIndex: Int) -> String
) -> String {
    let caseName = element.name.text
    guard let parameterClause = element.parameterClause,
          !parameterClause.parameters.isEmpty
    else {
        return ".\(caseName)"
    }

    let payload = parameterClause.parameters.enumerated().map { index, parameter in
        let pattern = payloadPattern(index)
        guard let label = enumCaseLabel(for: parameter) else {
            return pattern
        }

        return "\(label): \(pattern)"
    }
    .joined(separator: ", ")

    return ".\(caseName)(\(payload))"
}

/// Returns an enum-case payload label, excluding the unlabeled `_` spelling.
public func enumCaseLabel(for parameter: EnumCaseParameterSyntax) -> String? {
    guard let firstName = parameter.firstName,
          firstName.text != "_"
    else {
        return nil
    }

    return firstName.text
}
