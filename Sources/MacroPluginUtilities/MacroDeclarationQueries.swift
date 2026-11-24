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
    normalizedTypeText(type) == expectedTypeName
        || qualifiedTypeMatches(type, expected: expectedTypeName)
}

private func qualifiedTypeMatches(_ type: TypeSyntax, expected: String) -> Bool {
    guard !expected.isEmpty else {
        return false
    }

    if let optionalType = type.as(OptionalTypeSyntax.self) {
        guard expected.hasSuffix("?"),
              isPostfixAtomic(unwrapGroupingAndAny(optionalType.wrappedType))
        else {
            return false
        }
        return qualifiedTypeMatches(
            optionalType.wrappedType,
            expected: String(expected.dropLast())
        )
    }

    if let wrappedType = optionalWrappedType(type) {
        if qualifiedNominalMatches(type, expected: expected) {
            return true
        }
        guard expected.hasSuffix("?"),
              isPostfixAtomic(unwrapGroupingAndAny(wrappedType))
        else {
            return false
        }
        return qualifiedTypeMatches(
            wrappedType,
            expected: String(expected.dropLast())
        )
    }

    if let iuoType = type.as(ImplicitlyUnwrappedOptionalTypeSyntax.self) {
        guard expected.hasSuffix("!"),
              isPostfixAtomic(unwrapGroupingAndAny(iuoType.wrappedType))
        else {
            return false
        }
        return qualifiedTypeMatches(
            iuoType.wrappedType,
            expected: String(expected.dropLast())
        )
    }

    if let tupleType = type.as(TupleTypeSyntax.self),
       tupleType.elements.count == 1,
       let element = tupleType.elements.first,
       element.firstName == nil {
        return qualifiedTypeMatches(element.type, expected: expected)
    }

    if let someOrAnyType = type.as(SomeOrAnyTypeSyntax.self),
       someOrAnyType.someOrAnySpecifier.tokenKind == .keyword(.any) {
        return qualifiedTypeMatches(someOrAnyType.constraint, expected: expected)
    }

    if let metatype = type.as(MetatypeTypeSyntax.self) {
        return qualifiedMetatypeMatches(metatype, expected: expected)
    }

    return qualifiedNominalMatches(type, expected: expected)
}

private func qualifiedMetatypeMatches(
    _ metatype: MetatypeTypeSyntax,
    expected: String
) -> Bool {
    let suffix = ".\(metatype.metatypeSpecifier.text)"
    guard expected.hasSuffix(suffix) else {
        return false
    }
    let remainingExpected = String(expected.dropLast(suffix.count))
    if let nestedMetatype = metatype.baseType.as(MetatypeTypeSyntax.self) {
        return qualifiedMetatypeMatches(nestedMetatype, expected: remainingExpected)
    }
    return qualifiedNominalMatches(metatype.baseType, expected: remainingExpected)
}

private struct NominalASTSegment {
    let name: String
    let genericClause: GenericArgumentClauseSyntax?
}

private struct ExpectedNominalSegment {
    let name: String
    let genericBody: String?
}

private func qualifiedNominalMatches(_ type: TypeSyntax, expected: String) -> Bool {
    guard !expected.isEmpty,
          let astSegments = nominalASTSegments(for: type),
          let expectedSegments = parseExpectedNominalSegments(expected),
          expectedSegments.count <= astSegments.count
    else {
        return false
    }

    for (astSegment, expectedSegment) in zip(astSegments.suffix(expectedSegments.count), expectedSegments) {
        guard astSegment.name == expectedSegment.name else {
            return false
        }
        switch (astSegment.genericClause, expectedSegment.genericBody) {
        case (nil, nil):
            continue
        case (let clause?, let expectedBody?):
            if normalizedTokenText(clause) == "<\(expectedBody)>" {
                continue
            }
            guard let expectedArguments = splitTopLevel(expectedBody, separator: ","),
                  clause.arguments.count == expectedArguments.count
            else {
                return false
            }
            for (astArgument, expectedArgument) in zip(clause.arguments, expectedArguments) {
                guard case .type(let argumentType) = astArgument.argument,
                      typeMatches(argumentType, expectedTypeName: expectedArgument)
                else {
                    return false
                }
            }
        default:
            return false
        }
    }

    return true
}

private func nominalASTSegments(for type: TypeSyntax) -> [NominalASTSegment]? {
    if let identifierType = type.as(IdentifierTypeSyntax.self) {
        return [
            NominalASTSegment(
                name: identifierType.name.text,
                genericClause: identifierType.genericArgumentClause
            )
        ]
    }
    if let memberType = type.as(MemberTypeSyntax.self),
       let baseSegments = nominalASTSegments(for: memberType.baseType) {
        return baseSegments + [
            NominalASTSegment(
                name: memberType.name.text,
                genericClause: memberType.genericArgumentClause
            )
        ]
    }
    return nil
}

private func parseExpectedNominalSegments(_ expected: String) -> [ExpectedNominalSegment]? {
    guard let rawSegments = splitTopLevel(expected, separator: ".") else {
        return nil
    }

    var parsed: [ExpectedNominalSegment] = []
    parsed.reserveCapacity(rawSegments.count)

    for segment in rawSegments {
        if let openAngle = segment.firstIndex(of: "<") {
            let name = String(segment[..<openAngle])
            guard !name.isEmpty,
                  !name.contains(">"),
                  !name.contains(where: \.isWhitespace),
                  segment.last == ">"
            else {
                return nil
            }
            let bodyStart = segment.index(after: openAngle)
            let bodyEnd = segment.index(before: segment.endIndex)
            guard bodyStart < bodyEnd else {
                return nil
            }
            let body = String(segment[bodyStart..<bodyEnd])
            guard hasBalancedDelimiters(body) else {
                return nil
            }
            parsed.append(ExpectedNominalSegment(name: name, genericBody: body))
        } else {
            guard !segment.isEmpty,
                  !segment.contains(">"),
                  !segment.contains(where: \.isWhitespace)
            else {
                return nil
            }
            parsed.append(ExpectedNominalSegment(name: segment, genericBody: nil))
        }
    }

    return parsed
}

private func splitTopLevel(_ text: String, separator: Character) -> [String]? {
    var parts: [String] = []
    var currentStart = text.startIndex
    var angleDepth = 0
    var parenDepth = 0
    var bracketDepth = 0
    var index = text.startIndex

    while index < text.endIndex {
        let character = text[index]
        let nextIndex = text.index(after: index)

        if character == "-", nextIndex < text.endIndex, text[nextIndex] == ">" {
            index = text.index(after: nextIndex)
            continue
        }

        switch character {
        case "<":
            angleDepth += 1
        case ">":
            angleDepth -= 1
            if angleDepth < 0 { return nil }
        case "(":
            parenDepth += 1
        case ")":
            parenDepth -= 1
            if parenDepth < 0 { return nil }
        case "[":
            bracketDepth += 1
        case "]":
            bracketDepth -= 1
            if bracketDepth < 0 { return nil }
        case separator where angleDepth == 0 && parenDepth == 0 && bracketDepth == 0:
            let piece = trimmedWhitespace(text[currentStart..<index])
            guard !piece.isEmpty else { return nil }
            parts.append(piece)
            currentStart = nextIndex
        default:
            break
        }

        index = nextIndex
    }

    guard angleDepth == 0, parenDepth == 0, bracketDepth == 0 else {
        return nil
    }

    let trailing = trimmedWhitespace(text[currentStart..<text.endIndex])
    guard !trailing.isEmpty else {
        return nil
    }
    parts.append(trailing)
    return parts
}

private func trimmedWhitespace(_ substring: Substring) -> String {
    var start = substring.startIndex
    var end = substring.endIndex
    while start < end, substring[start].isWhitespace {
        start = substring.index(after: start)
    }
    while end > start {
        let beforeEnd = substring.index(before: end)
        guard substring[beforeEnd].isWhitespace else { break }
        end = beforeEnd
    }
    return String(substring[start..<end])
}

private func hasBalancedDelimiters(_ text: String) -> Bool {
    var angleDepth = 0
    var parenDepth = 0
    var bracketDepth = 0
    var index = text.startIndex

    while index < text.endIndex {
        let character = text[index]
        let nextIndex = text.index(after: index)

        if character == "-", nextIndex < text.endIndex, text[nextIndex] == ">" {
            index = text.index(after: nextIndex)
            continue
        }

        switch character {
        case "<":
            angleDepth += 1
        case ">":
            angleDepth -= 1
            if angleDepth < 0 { return false }
        case "(":
            parenDepth += 1
        case ")":
            parenDepth -= 1
            if parenDepth < 0 { return false }
        case "[":
            bracketDepth += 1
        case "]":
            bracketDepth -= 1
            if bracketDepth < 0 { return false }
        default:
            break
        }

        index = nextIndex
    }

    return angleDepth == 0 && parenDepth == 0 && bracketDepth == 0
}

private func optionalWrappedType(_ type: TypeSyntax) -> TypeSyntax? {
    if let identifierType = type.as(IdentifierTypeSyntax.self),
       identifierType.name.text == "Optional",
       let arguments = identifierType.genericArgumentClause?.arguments,
       arguments.count == 1,
       let argument = arguments.first,
       case .type(let wrappedType) = argument.argument {
        return wrappedType
    }

    guard let memberType = type.as(MemberTypeSyntax.self),
          memberType.name.text == "Optional",
          let baseIdentifier = memberType.baseType.as(IdentifierTypeSyntax.self),
          baseIdentifier.name.text == "Swift",
          baseIdentifier.genericArgumentClause == nil,
          let arguments = memberType.genericArgumentClause?.arguments,
          arguments.count == 1,
          let argument = arguments.first,
          case .type(let wrappedType) = argument.argument
    else {
        return nil
    }

    return wrappedType
}

/// Renders a type in the canonical spelling used by expected-type tables:
/// optionals as `?`, `any` markers dropped, single-element parentheses
/// unwrapped when precedence allows, non-boundary whitespace removed. Adjacent
/// word tokens keep a separating space so opaque and ownership keywords remain
/// distinct.
private func normalizedTypeText(_ type: TypeSyntax) -> String {
    if let optionalType = type.as(OptionalTypeSyntax.self) {
        return normalizedPostfixBaseText(optionalType.wrappedType) + "?"
    }

    if let wrappedType = optionalWrappedType(type) {
        return normalizedPostfixBaseText(wrappedType) + "?"
    }

    if let iuoType = type.as(ImplicitlyUnwrappedOptionalTypeSyntax.self) {
        return normalizedPostfixBaseText(iuoType.wrappedType) + "!"
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

    return normalizedTokenText(type)
}

private func normalizedPostfixBaseText(_ base: TypeSyntax) -> String {
    let rendered = normalizedTypeText(base)
    return isPostfixAtomic(unwrapGroupingAndAny(base)) ? rendered : "(\(rendered))"
}

private func unwrapGroupingAndAny(_ type: TypeSyntax) -> TypeSyntax {
    if let tupleType = type.as(TupleTypeSyntax.self),
       tupleType.elements.count == 1,
       let element = tupleType.elements.first,
       element.firstName == nil {
        return unwrapGroupingAndAny(element.type)
    }

    if let someOrAnyType = type.as(SomeOrAnyTypeSyntax.self),
       someOrAnyType.someOrAnySpecifier.tokenKind == .keyword(.any) {
        return unwrapGroupingAndAny(someOrAnyType.constraint)
    }

    return type
}

private func isPostfixAtomic(_ type: TypeSyntax) -> Bool {
    type.is(IdentifierTypeSyntax.self)
        || type.is(MemberTypeSyntax.self)
        || type.is(ArrayTypeSyntax.self)
        || type.is(DictionaryTypeSyntax.self)
        || type.is(OptionalTypeSyntax.self)
        || type.is(ImplicitlyUnwrappedOptionalTypeSyntax.self)
        || type.is(MetatypeTypeSyntax.self)
        || type.is(TupleTypeSyntax.self)
}

private func normalizedTokenText(_ node: some SyntaxProtocol) -> String {
    var result = ""
    var previousWasWordToken = false

    for token in node.tokens(viewMode: .sourceAccurate) {
        let isWordToken = isTypeWordToken(token.tokenKind)
        if previousWasWordToken && isWordToken {
            result.append(" ")
        }
        result.append(token.text)
        previousWasWordToken = isWordToken
    }

    return result
}

private func isTypeWordToken(_ kind: TokenKind) -> Bool {
    switch kind {
    case .identifier, .keyword, .wildcard, .dollarIdentifier, .integerLiteral, .floatLiteral:
        true
    default:
        false
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
