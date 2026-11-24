import SwiftParser
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
    guard let expectedType = parseExpectedType(expectedTypeName) else {
        return false
    }

    return typeSyntaxMatches(type, expectedType, allowExistentialUnwrap: true)
}

private func parseExpectedType(_ text: String) -> TypeSyntax? {
    guard text.contains(where: { !$0.isWhitespace }) else {
        return nil
    }

    var parser = Parser(text)
    let parsed = TypeSyntax.parse(from: &parser)
    guard !parsed.hasError, parsed.totalLength.utf8Length == text.utf8.count else {
        return nil
    }

    return parsed
}

private func typeSyntaxMatches(
    _ actual: TypeSyntax,
    _ expected: TypeSyntax,
    allowExistentialUnwrap: Bool
) -> Bool {
    let lhs = unwrapGrouping(actual)
    let rhs = unwrapGrouping(expected)

    if allowExistentialUnwrap {
        if let lhsExistential = existentialConstraint(of: lhs) {
            guard isValidExistentialConstraint(lhsExistential) else {
                return false
            }
            return typeSyntaxMatches(lhsExistential, rhs, allowExistentialUnwrap: true)
        }
        if let rhsExistential = existentialConstraint(of: rhs) {
            guard isValidExistentialConstraint(rhsExistential) else {
                return false
            }
            return typeSyntaxMatches(lhs, rhsExistential, allowExistentialUnwrap: true)
        }
    } else {
        let lhsExistential = existentialConstraint(of: lhs)
        let rhsExistential = existentialConstraint(of: rhs)
        if lhsExistential != nil || rhsExistential != nil {
            guard let lhsConstraint = lhsExistential,
                  let rhsConstraint = rhsExistential,
                  isValidExistentialConstraint(lhsConstraint),
                  isValidExistentialConstraint(rhsConstraint)
            else {
                return false
            }
            return typeSyntaxMatches(lhsConstraint, rhsConstraint, allowExistentialUnwrap: false)
        }
    }

    let lhsOptional = standardOptionalWrappedType(lhs)
    let rhsOptional = standardOptionalWrappedType(rhs)
    if lhsOptional != nil || rhsOptional != nil {
        guard let lhsWrapped = lhsOptional, let rhsWrapped = rhsOptional else {
            return false
        }
        return typeSyntaxMatches(lhsWrapped, rhsWrapped, allowExistentialUnwrap: true)
    }

    let lhsIUO = lhs.as(ImplicitlyUnwrappedOptionalTypeSyntax.self)
    let rhsIUO = rhs.as(ImplicitlyUnwrappedOptionalTypeSyntax.self)
    if lhsIUO != nil || rhsIUO != nil {
        guard let lhsIUO, let rhsIUO else {
            return false
        }
        return typeSyntaxMatches(lhsIUO.wrappedType, rhsIUO.wrappedType, allowExistentialUnwrap: true)
    }

    let lhsMetatype = lhs.as(MetatypeTypeSyntax.self)
    let rhsMetatype = rhs.as(MetatypeTypeSyntax.self)
    if lhsMetatype != nil || rhsMetatype != nil {
        guard let lhsMetatype,
              let rhsMetatype,
              lhsMetatype.metatypeSpecifier.text == rhsMetatype.metatypeSpecifier.text
        else {
            return false
        }
        return typeSyntaxMatches(
            lhsMetatype.baseType,
            rhsMetatype.baseType,
            allowExistentialUnwrap: false
        )
    }

    let lhsComposition = lhs.as(CompositionTypeSyntax.self)
    let rhsComposition = rhs.as(CompositionTypeSyntax.self)
    if lhsComposition != nil || rhsComposition != nil {
        guard let lhsComposition,
              let rhsComposition,
              lhsComposition.elements.count == rhsComposition.elements.count
        else {
            return false
        }
        return zip(lhsComposition.elements, rhsComposition.elements).allSatisfy { lElement, rElement in
            typeSyntaxMatches(
                lElement.type,
                rElement.type,
                allowExistentialUnwrap: allowExistentialUnwrap
            )
        }
    }

    let lhsArray = lhs.as(ArrayTypeSyntax.self)
    let rhsArray = rhs.as(ArrayTypeSyntax.self)
    if lhsArray != nil || rhsArray != nil {
        guard let lhsArray, let rhsArray else {
            return false
        }
        return typeSyntaxMatches(lhsArray.element, rhsArray.element, allowExistentialUnwrap: true)
    }

    let lhsDictionary = lhs.as(DictionaryTypeSyntax.self)
    let rhsDictionary = rhs.as(DictionaryTypeSyntax.self)
    if lhsDictionary != nil || rhsDictionary != nil {
        guard let lhsDictionary, let rhsDictionary else {
            return false
        }
        return typeSyntaxMatches(lhsDictionary.key, rhsDictionary.key, allowExistentialUnwrap: true)
            && typeSyntaxMatches(lhsDictionary.value, rhsDictionary.value, allowExistentialUnwrap: true)
    }

    let lhsInlineArray = lhs.as(InlineArrayTypeSyntax.self)
    let rhsInlineArray = rhs.as(InlineArrayTypeSyntax.self)
    if lhsInlineArray != nil || rhsInlineArray != nil {
        guard let lhsInlineArray, let rhsInlineArray else {
            return false
        }
        return genericArgumentMatches(lhsInlineArray.count.argument, rhsInlineArray.count.argument)
            && genericArgumentMatches(lhsInlineArray.element.argument, rhsInlineArray.element.argument)
    }

    let lhsTuple = lhs.as(TupleTypeSyntax.self)
    let rhsTuple = rhs.as(TupleTypeSyntax.self)
    if lhsTuple != nil || rhsTuple != nil {
        guard let lhsTuple,
              let rhsTuple,
              lhsTuple.elements.count == rhsTuple.elements.count
        else {
            return false
        }
        return zip(lhsTuple.elements, rhsTuple.elements).allSatisfy { lElement, rElement in
            lElement.firstName?.text == rElement.firstName?.text
                && lElement.secondName?.text == rElement.secondName?.text
                && typeSyntaxMatches(lElement.type, rElement.type, allowExistentialUnwrap: true)
        }
    }

    let lhsSuppressed = lhs.as(SuppressedTypeSyntax.self)
    let rhsSuppressed = rhs.as(SuppressedTypeSyntax.self)
    if lhsSuppressed != nil || rhsSuppressed != nil {
        guard let lhsSuppressed, let rhsSuppressed else {
            return false
        }
        return typeSyntaxMatches(
            lhsSuppressed.type,
            rhsSuppressed.type,
            allowExistentialUnwrap: false
        )
    }

    if let lhsSegments = nominalASTSegments(for: lhs),
       let rhsSegments = nominalASTSegments(for: rhs) {
        return nominalSegmentsMatch(lhsSegments, rhsSegments)
    }

    return normalizedTokenText(lhs) == normalizedTokenText(rhs)
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

private func existentialConstraint(of type: TypeSyntax) -> TypeSyntax? {
    guard let someOrAny = type.as(SomeOrAnyTypeSyntax.self),
          someOrAny.someOrAnySpecifier.tokenKind == .keyword(.any)
    else {
        return nil
    }

    return someOrAny.constraint
}

private func isValidExistentialConstraint(_ constraint: TypeSyntax) -> Bool {
    let unwrapped = unwrapGrouping(constraint)
    if unwrapped.is(IdentifierTypeSyntax.self) || unwrapped.is(MemberTypeSyntax.self) {
        return optionalWrappedType(unwrapped) == nil
    }
    if let metatype = unwrapped.as(MetatypeTypeSyntax.self) {
        return isValidExistentialConstraint(metatype.baseType)
    }
    if let composition = unwrapped.as(CompositionTypeSyntax.self) {
        return composition.elements.allSatisfy { element in
            unwrapGrouping(element.type).is(SuppressedTypeSyntax.self)
                || isValidExistentialConstraint(element.type)
        }
    }

    return false
}

private func standardOptionalWrappedType(_ type: TypeSyntax) -> TypeSyntax? {
    if let optionalType = type.as(OptionalTypeSyntax.self) {
        return optionalType.wrappedType
    }

    return optionalWrappedType(type)
}

private func optionalWrappedType(_ type: TypeSyntax) -> TypeSyntax? {
    if let identifierType = type.as(IdentifierTypeSyntax.self),
       identifierType.moduleSelector == nil,
       identifierType.name.text == "Optional",
       let arguments = identifierType.genericArgumentClause?.arguments,
       arguments.count == 1,
       let argument = arguments.first,
       case .type(let wrappedType) = argument.argument {
        return wrappedType
    }

    guard let memberType = type.as(MemberTypeSyntax.self),
          memberType.moduleSelector == nil,
          memberType.name.text == "Optional",
          let baseIdentifier = memberType.baseType.as(IdentifierTypeSyntax.self),
          baseIdentifier.moduleSelector == nil,
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

private struct NominalASTSegment {
    let moduleSelector: String?
    let name: String
    let genericClause: GenericArgumentClauseSyntax?

    var isUnqualifiedStandardOptional: Bool {
        guard moduleSelector == nil,
              name == "Optional",
              let arguments = genericClause?.arguments,
              arguments.count == 1,
              let argument = arguments.first,
              case .type = argument.argument
        else {
            return false
        }

        return true
    }

    var isPlainSwiftNamespace: Bool {
        moduleSelector == nil && name == "Swift" && genericClause == nil
    }
}

private func nominalASTSegments(for type: TypeSyntax) -> [NominalASTSegment]? {
    if let identifierType = type.as(IdentifierTypeSyntax.self) {
        return [
            NominalASTSegment(
                moduleSelector: identifierType.moduleSelector?.moduleName.text,
                name: identifierType.name.text,
                genericClause: identifierType.genericArgumentClause
            )
        ]
    }
    if let memberType = type.as(MemberTypeSyntax.self),
       let baseSegments = nominalASTSegments(for: memberType.baseType) {
        return baseSegments + [
            NominalASTSegment(
                moduleSelector: memberType.moduleSelector?.moduleName.text,
                name: memberType.name.text,
                genericClause: memberType.genericArgumentClause
            )
        ]
    }
    return nil
}

private func nominalSegmentsMatch(
    _ lhsSegments: [NominalASTSegment],
    _ rhsSegments: [NominalASTSegment]
) -> Bool {
    var expected = rhsSegments[...]
    if expected.count >= 2,
       expected[expected.startIndex].isPlainSwiftNamespace,
       expected[expected.index(after: expected.startIndex)].isUnqualifiedStandardOptional,
       let firstActual = lhsSegments.first,
       firstActual.isUnqualifiedStandardOptional {
        expected = expected.dropFirst()
    }

    guard expected.count <= lhsSegments.count else {
        return false
    }

    let droppedPrefixCount = lhsSegments.count - expected.count
    let droppedPrefix = lhsSegments.prefix(droppedPrefixCount)
    guard droppedPrefix.allSatisfy({ $0.genericClause == nil && $0.moduleSelector == nil }) else {
        return false
    }

    if !droppedPrefix.isEmpty {
        if expected.count >= 2,
           expected[expected.startIndex].isPlainSwiftNamespace,
           expected[expected.index(after: expected.startIndex)].isUnqualifiedStandardOptional {
            return false
        }
        if expected[expected.startIndex].isUnqualifiedStandardOptional {
            guard droppedPrefix.count == 1,
                  droppedPrefix.first?.isPlainSwiftNamespace == true
            else {
                return false
            }
        }
    }

    for (lhsSegment, rhsSegment) in zip(lhsSegments.suffix(expected.count), expected) {
        guard lhsSegment.moduleSelector == rhsSegment.moduleSelector,
              lhsSegment.name == rhsSegment.name
        else {
            return false
        }
        switch (lhsSegment.genericClause, rhsSegment.genericClause) {
        case (nil, nil):
            continue
        case (let lhsClause?, let rhsClause?):
            guard lhsClause.arguments.count == rhsClause.arguments.count else {
                return false
            }
            for (lhsArgument, rhsArgument) in zip(lhsClause.arguments, rhsClause.arguments) {
                guard genericArgumentMatches(lhsArgument.argument, rhsArgument.argument) else {
                    return false
                }
            }
        default:
            return false
        }
    }

    return true
}

private func genericArgumentMatches(
    _ actual: GenericArgumentSyntax.Argument,
    _ expected: GenericArgumentSyntax.Argument
) -> Bool {
    switch (actual, expected) {
    case (.type(let actualType), .type(let expectedType)):
        typeSyntaxMatches(actualType, expectedType, allowExistentialUnwrap: true)
    case (.expr(let actualExpr), .expr(let expectedExpr)):
        normalizedTokenText(actualExpr) == normalizedTokenText(expectedExpr)
    default:
        false
    }
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
