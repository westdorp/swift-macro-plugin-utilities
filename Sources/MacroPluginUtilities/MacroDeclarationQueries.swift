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
    if normalized == expectedTypeName {
        return true
    }
    return isQualificationMatchable(unwrappedBaseType(type))
        && normalized.hasSuffix(".\(expectedTypeName)")
}

private func unwrappedBaseType(_ type: TypeSyntax) -> TypeSyntax {
    if let optionalType = type.as(OptionalTypeSyntax.self) {
        return unwrappedBaseType(optionalType.wrappedType)
    }

    if let identifierType = type.as(IdentifierTypeSyntax.self),
       identifierType.name.text == "Optional",
       let arguments = identifierType.genericArgumentClause?.arguments,
       arguments.count == 1,
       let argument = arguments.first,
       case .type(let wrappedType) = argument.argument {
        return unwrappedBaseType(wrappedType)
    }

    if let tupleType = type.as(TupleTypeSyntax.self),
       tupleType.elements.count == 1,
       let element = tupleType.elements.first,
       element.firstName == nil {
        return unwrappedBaseType(element.type)
    }

    if let someOrAnyType = type.as(SomeOrAnyTypeSyntax.self),
       someOrAnyType.someOrAnySpecifier.tokenKind == .keyword(.any) {
        return unwrappedBaseType(someOrAnyType.constraint)
    }

    return type
}

private func isQualificationMatchable(_ type: TypeSyntax) -> Bool {
    if type.is(IdentifierTypeSyntax.self) {
        return true
    }
    if let memberType = type.as(MemberTypeSyntax.self) {
        return isQualificationMatchable(unwrappedBaseType(memberType.baseType))
    }
    if let metatype = type.as(MetatypeTypeSyntax.self) {
        return isQualificationMatchable(unwrappedBaseType(metatype.baseType))
    }
    return false
}

/// Renders a type in the canonical spelling used by expected-type tables:
/// optionals as `?`, `any` markers dropped, single-element parentheses
/// unwrapped, non-boundary whitespace removed. Adjacent word tokens keep a
/// separating space so opaque and ownership keywords remain distinct.
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

    if let metatype = type.as(MetatypeTypeSyntax.self) {
        return normalizedTypeText(metatype.baseType) + "." + metatype.metatypeSpecifier.text
    }

    return normalizedTokenText(type)
}

private func normalizedTokenText(_ node: some SyntaxProtocol) -> String {
    var result = ""
    var previousEndedWithWord = false

    for token in node.tokens(viewMode: .sourceAccurate) {
        let text = token.text
        guard let first = text.first, let last = text.last else {
            continue
        }
        let startsWithWord = isTypeWordCharacter(first)
        if previousEndedWithWord && startsWithWord {
            result.append(" ")
        }
        result.append(text)
        previousEndedWithWord = isTypeWordCharacter(last)
    }

    return result
}

private func isTypeWordCharacter(_ character: Character) -> Bool {
    character.isLetter || character.isNumber || character == "_" || character == "`"
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
