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

    let (unwrappedExpected, expectedHadParentheses) = stripBalancedOuterParentheses(expected)
    if expectedHadParentheses {
        return typeMatches(type, expectedTypeName: unwrappedExpected)
    }

    if !expected.hasSuffix("?"),
       !expected.hasSuffix("!"),
       let constraintExpected = strippingLeadingAnyKeyword(from: expected) {
        guard strippingLeadingAnyKeyword(from: constraintExpected) == nil else {
            return false
        }
        return typeMatches(type, expectedTypeName: constraintExpected)
    }

    if let optionalType = type.as(OptionalTypeSyntax.self) {
        return qualifiedOptionalMatches(
            wrappedType: optionalType.wrappedType,
            expected: expected
        )
    }

    if let wrappedType = optionalWrappedType(type) {
        return qualifiedNominalMatches(type, expected: expected)
            || qualifiedOptionalMatches(wrappedType: wrappedType, expected: expected)
    }

    if let iuoType = type.as(ImplicitlyUnwrappedOptionalTypeSyntax.self) {
        return qualifiedImplicitlyUnwrappedOptionalMatches(
            wrappedType: iuoType.wrappedType,
            expected: expected
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

    if let composition = type.as(CompositionTypeSyntax.self) {
        return qualifiedCompositionMatches(composition, expected: expected)
    }

    if let metatype = type.as(MetatypeTypeSyntax.self) {
        return qualifiedMetatypeMatches(metatype, expected: expected)
    }

    return qualifiedNominalMatches(type, expected: expected)
}

private func qualifiedOptionalMatches(
    wrappedType: TypeSyntax,
    expected: String
) -> Bool {
    guard let (rawExpectedWrapped, isSugar) = expectedOptionalWrapped(expected) else {
        return false
    }

    let (unwrappedExpected, expectedHadParentheses) = stripBalancedOuterParentheses(rawExpectedWrapped)
    if isSugar,
       !expectedHadParentheses,
       !isPostfixAtomic(unwrapGroupingAndAny(wrappedType))
        || strippingLeadingAnyKeyword(from: unwrappedExpected) != nil {
        return false
    }

    return typeMatches(wrappedType, expectedTypeName: unwrappedExpected)
}

private func expectedOptionalWrapped(_ expected: String) -> (wrapped: String, isSugar: Bool)? {
    if expected.hasSuffix("?") {
        let wrapped = String(expected.dropLast())
        return wrapped.isEmpty ? nil : (wrapped, true)
    }

    guard let segments = parseExpectedNominalSegments(expected) else {
        return nil
    }

    let genericBody: String?
    switch segments.count {
    case 1 where segments[0].name == "Optional":
        genericBody = segments[0].genericBody
    case 2 where segments[0].name == "Swift"
        && segments[0].genericBody == nil
        && segments[1].name == "Optional":
        genericBody = segments[1].genericBody
    default:
        return nil
    }

    guard let genericBody,
          let arguments = splitTopLevel(genericBody, separator: ","),
          arguments.count == 1,
          let wrapped = arguments.first
    else {
        return nil
    }

    return (wrapped, false)
}

private func qualifiedImplicitlyUnwrappedOptionalMatches(
    wrappedType: TypeSyntax,
    expected: String
) -> Bool {
    guard expected.hasSuffix("!") else {
        return false
    }

    let rawExpectedWrapped = String(expected.dropLast())
    let (unwrappedExpected, expectedHadParentheses) = stripBalancedOuterParentheses(rawExpectedWrapped)
    if !expectedHadParentheses,
       !isPostfixAtomic(unwrapGroupingAndAny(wrappedType))
        || strippingLeadingAnyKeyword(from: unwrappedExpected) != nil {
        return false
    }

    return typeMatches(wrappedType, expectedTypeName: unwrappedExpected)
}

private func qualifiedCompositionMatches(
    _ composition: CompositionTypeSyntax,
    expected: String
) -> Bool {
    guard let expectedElements = splitTopLevel(expected, separator: "&"),
          composition.elements.count == expectedElements.count
    else {
        return false
    }

    for (astElement, expectedElement) in zip(composition.elements, expectedElements) {
        guard typeMatches(astElement.type, expectedTypeName: expectedElement) else {
            return false
        }
    }

    return true
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
    return qualifiedMetatypeBaseMatches(metatype.baseType, expected: remainingExpected)
}

private func qualifiedMetatypeBaseMatches(_ base: TypeSyntax, expected: String) -> Bool {
    let unwrappedBase = unwrapGrouping(base)
    let (unwrappedExpected, expectedHadParentheses) = stripBalancedOuterParentheses(expected)

    if let someOrAnyType = unwrappedBase.as(SomeOrAnyTypeSyntax.self),
       someOrAnyType.someOrAnySpecifier.tokenKind == .keyword(.any) {
        guard expectedHadParentheses,
              let constraintExpected = strippingLeadingAnyKeyword(from: unwrappedExpected)
        else {
            return false
        }
        let unwrappedConstraint = unwrapGrouping(someOrAnyType.constraint)
        if let composition = unwrappedConstraint.as(CompositionTypeSyntax.self) {
            let (innerExpected, _) = stripBalancedOuterParentheses(constraintExpected)
            return qualifiedCompositionMatches(composition, expected: innerExpected)
        }
        return qualifiedMetatypeBaseMatches(someOrAnyType.constraint, expected: constraintExpected)
    }

    if (expectedHadParentheses || isPostfixAtomic(unwrappedBase)),
       normalizedTypeText(unwrappedBase) == unwrappedExpected {
        return true
    }

    if let nestedMetatype = unwrappedBase.as(MetatypeTypeSyntax.self) {
        return qualifiedMetatypeMatches(nestedMetatype, expected: unwrappedExpected)
    }

    if let composition = unwrappedBase.as(CompositionTypeSyntax.self) {
        guard expectedHadParentheses else {
            return false
        }
        return qualifiedCompositionMatches(composition, expected: unwrappedExpected)
    }

    if let optionalType = unwrappedBase.as(OptionalTypeSyntax.self) {
        return qualifiedOptionalMatches(
            wrappedType: optionalType.wrappedType,
            expected: unwrappedExpected
        )
    }

    if let wrappedType = optionalWrappedType(unwrappedBase) {
        return qualifiedNominalMatches(unwrappedBase, expected: unwrappedExpected)
            || qualifiedOptionalMatches(wrappedType: wrappedType, expected: unwrappedExpected)
    }

    if let iuoType = unwrappedBase.as(ImplicitlyUnwrappedOptionalTypeSyntax.self) {
        return qualifiedImplicitlyUnwrappedOptionalMatches(
            wrappedType: iuoType.wrappedType,
            expected: unwrappedExpected
        )
    }

    return qualifiedNominalMatches(unwrappedBase, expected: unwrappedExpected)
}

private func unwrapGrouping(_ type: TypeSyntax) -> TypeSyntax {
    if let tupleType = type.as(TupleTypeSyntax.self),
       tupleType.elements.count == 1,
       let element = tupleType.elements.first,
       element.firstName == nil {
        return unwrapGrouping(element.type)
    }

    return type
}

private func strippingLeadingAnyKeyword(from text: String) -> String? {
    guard text.hasPrefix("any") else {
        return nil
    }
    let afterAny = text.dropFirst(3)
    guard let firstAfterAny = afterAny.first, firstAfterAny.isWhitespace else {
        return nil
    }
    let remainder = trimmedWhitespace(afterAny)
    return remainder.isEmpty ? nil : remainder
}

private func stripBalancedOuterParentheses(_ text: String) -> (inner: String, hadParentheses: Bool) {
    var current = trimmedWhitespace(text[...])
    var strippedAny = false

    while let inner = stripOneBalancedOuterParentheses(current) {
        current = inner
        strippedAny = true
    }

    return (current, strippedAny)
}

private func stripOneBalancedOuterParentheses(_ text: String) -> String? {
    guard text.first == "(", text.last == ")" else {
        return nil
    }

    var parenDepth = 0
    var angleDepth = 0
    var bracketDepth = 0
    var index = text.startIndex
    let lastIndex = text.index(before: text.endIndex)

    while index < text.endIndex {
        let character = text[index]
        let nextIndex = text.index(after: index)

        if character == "-", nextIndex < text.endIndex, text[nextIndex] == ">" {
            index = text.index(after: nextIndex)
            continue
        }

        switch character {
        case "(":
            parenDepth += 1
        case ")":
            parenDepth -= 1
            if parenDepth < 0 { return nil }
            if parenDepth == 0 && index != lastIndex {
                return nil
            }
        case "<":
            angleDepth += 1
        case ">":
            angleDepth -= 1
            if angleDepth < 0 { return nil }
        case "[":
            bracketDepth += 1
        case "]":
            bracketDepth -= 1
            if bracketDepth < 0 { return nil }
        case "," where parenDepth == 1 && angleDepth == 0 && bracketDepth == 0:
            return nil
        default:
            break
        }

        index = nextIndex
    }

    guard parenDepth == 0, angleDepth == 0, bracketDepth == 0 else {
        return nil
    }

    let innerStart = text.index(after: text.startIndex)
    let inner = trimmedWhitespace(text[innerStart..<lastIndex])
    return inner.isEmpty ? nil : inner
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

    let droppedPrefixCount = astSegments.count - expectedSegments.count
    guard astSegments.prefix(droppedPrefixCount).allSatisfy({ $0.genericClause == nil }) else {
        return false
    }

    if expectedSegments.count == 1,
       expectedSegments[0].name == "Optional",
       let genericBody = expectedSegments[0].genericBody,
       let expectedArgs = splitTopLevel(genericBody, separator: ","),
       expectedArgs.count == 1,
       optionalWrappedType(type) == nil {
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
                switch astArgument.argument {
                case .type(let argumentType):
                    guard typeMatches(argumentType, expectedTypeName: expectedArgument) else {
                        return false
                    }
                case .expr(let argumentExpr):
                    guard normalizedTokenText(argumentExpr) == expectedArgument else {
                        return false
                    }
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
