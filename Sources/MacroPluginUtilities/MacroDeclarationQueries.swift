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

    return typeMatches(type, expectedType: expectedType)
}

func typeMatches(_ type: TypeSyntax, expectedType: TypeSyntax) -> Bool {
    guard !type.hasError else {
        return false
    }

    return typeSyntaxMatches(type, expectedType, allowExistentialUnwrap: true)
}

func parseExpectedType(_ text: String) -> TypeSyntax? {
    guard let firstNonWhitespace = text.firstIndex(where: { !$0.isWhitespace }),
          let lastNonWhitespace = text.lastIndex(where: { !$0.isWhitespace })
    else {
        return nil
    }

    let trimmed = String(text[firstNonWhitespace...lastNonWhitespace])
    var parser = Parser(trimmed)
    let parsed = TypeSyntax.parse(from: &parser)
    guard !parsed.hasError, parsed.totalLength.utf8Length == trimmed.utf8.count else {
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

    let lhsOpaque = opaqueConstraint(of: lhs)
    let rhsOpaque = opaqueConstraint(of: rhs)
    if lhsOpaque != nil || rhsOpaque != nil {
        guard let lhsConstraint = lhsOpaque,
              let rhsConstraint = rhsOpaque,
              isValidOpaqueConstraint(lhsConstraint),
              isValidOpaqueConstraint(rhsConstraint)
        else {
            return false
        }
        return typeSyntaxMatches(lhsConstraint, rhsConstraint, allowExistentialUnwrap: false)
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
            !unwrapGrouping(lElement.type).is(SomeOrAnyTypeSyntax.self)
                && !unwrapGrouping(rElement.type).is(SomeOrAnyTypeSyntax.self)
                && typeSyntaxMatches(
                    lElement.type,
                    rElement.type,
                    allowExistentialUnwrap: false
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
        guard let lhsTuple, let rhsTuple else {
            return false
        }
        return tupleElementsMatch(lhsTuple.elements, rhsTuple.elements)
    }

    let lhsFunction = lhs.as(FunctionTypeSyntax.self)
    let rhsFunction = rhs.as(FunctionTypeSyntax.self)
    if lhsFunction != nil || rhsFunction != nil {
        guard let lhsFunction, let rhsFunction else {
            return false
        }
        return functionTypesMatch(lhsFunction, rhsFunction)
    }

    let lhsAttributed = lhs.as(AttributedTypeSyntax.self)
    let rhsAttributed = rhs.as(AttributedTypeSyntax.self)
    if lhsAttributed != nil || rhsAttributed != nil {
        guard let lhsAttributed,
              let rhsAttributed,
              normalizedTokenText(lhsAttributed.specifiers) == normalizedTokenText(rhsAttributed.specifiers),
              normalizedTokenText(lhsAttributed.attributes) == normalizedTokenText(rhsAttributed.attributes),
              normalizedTokenText(lhsAttributed.lateSpecifiers) == normalizedTokenText(rhsAttributed.lateSpecifiers)
        else {
            return false
        }
        return typeSyntaxMatches(
            lhsAttributed.baseType,
            rhsAttributed.baseType,
            allowExistentialUnwrap: allowExistentialUnwrap
        )
    }

    let lhsPackExpansion = lhs.as(PackExpansionTypeSyntax.self)
    let rhsPackExpansion = rhs.as(PackExpansionTypeSyntax.self)
    if lhsPackExpansion != nil || rhsPackExpansion != nil {
        guard let lhsPackExpansion, let rhsPackExpansion else {
            return false
        }
        return typeSyntaxMatches(
            lhsPackExpansion.repetitionPattern,
            rhsPackExpansion.repetitionPattern,
            allowExistentialUnwrap: true
        )
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

    if let lhsChain = memberTypeChain(for: lhs),
       let rhsChain = memberTypeChain(for: rhs) {
        return memberTypeChainsMatch(lhsChain, rhsChain)
    }

    return normalizedTokenText(lhs) == normalizedTokenText(rhs)
}

private func tupleElementsMatch(
    _ lhs: TupleTypeElementListSyntax,
    _ rhs: TupleTypeElementListSyntax
) -> Bool {
    guard lhs.count == rhs.count else {
        return false
    }

    return zip(lhs, rhs).allSatisfy { lElement, rElement in
        lElement.firstName?.text == rElement.firstName?.text
            && lElement.secondName?.text == rElement.secondName?.text
            && (lElement.ellipsis != nil) == (rElement.ellipsis != nil)
            && typeSyntaxMatches(
                effectiveTupleElementType(lElement),
                effectiveTupleElementType(rElement),
                allowExistentialUnwrap: true
            )
    }
}

private func functionParametersMatch(
    _ lhs: TupleTypeElementListSyntax,
    _ rhs: TupleTypeElementListSyntax
) -> Bool {
    guard lhs.count == rhs.count else {
        return false
    }

    return zip(lhs, rhs).allSatisfy { lElement, rElement in
        isValidFunctionParameterLabel(lElement)
            && isValidFunctionParameterLabel(rElement)
            && (lElement.ellipsis != nil) == (rElement.ellipsis != nil)
            && typeSyntaxMatches(
                effectiveTupleElementType(lElement),
                effectiveTupleElementType(rElement),
                allowExistentialUnwrap: true
            )
    }
}

private func effectiveTupleElementType(_ element: TupleTypeElementSyntax) -> TypeSyntax {
    guard let inoutKeyword = element.inoutKeyword else {
        return element.type
    }

    let inoutSpecifier = TypeSpecifierListSyntax.Element.simpleTypeSpecifier(
        SimpleTypeSpecifierSyntax(specifier: inoutKeyword.trimmed)
    )
    if let attributed = element.type.as(AttributedTypeSyntax.self) {
        var specifiers = Array(attributed.specifiers)
        specifiers.insert(inoutSpecifier, at: 0)
        return TypeSyntax(attributed.with(\.specifiers, TypeSpecifierListSyntax(specifiers)))
    }

    return TypeSyntax(
        AttributedTypeSyntax(
            specifiers: TypeSpecifierListSyntax([inoutSpecifier]),
            attributes: AttributeListSyntax([]),
            lateSpecifiers: TypeSpecifierListSyntax([]),
            baseType: element.type
        )
    )
}

private func isValidFunctionParameterLabel(_ element: TupleTypeElementSyntax) -> Bool {
    guard let firstName = element.firstName else {
        return true
    }

    return firstName.text == "_"
}

private func functionTypesMatch(
    _ lhs: FunctionTypeSyntax,
    _ rhs: FunctionTypeSyntax
) -> Bool {
    guard functionParametersMatch(lhs.parameters, rhs.parameters),
          effectSpecifiersMatch(lhs.effectSpecifiers, rhs.effectSpecifiers)
    else {
        return false
    }

    return typeSyntaxMatches(
        lhs.returnClause.type,
        rhs.returnClause.type,
        allowExistentialUnwrap: true
    )
}

private func effectSpecifiersMatch(
    _ lhs: TypeEffectSpecifiersSyntax?,
    _ rhs: TypeEffectSpecifiersSyntax?
) -> Bool {
    guard lhs?.asyncSpecifier?.text == rhs?.asyncSpecifier?.text else {
        return false
    }

    switch (lhs?.throwsClause, rhs?.throwsClause) {
    case (nil, nil):
        return true
    case (let lhsThrows?, let rhsThrows?):
        guard lhsThrows.throwsSpecifier.text == rhsThrows.throwsSpecifier.text else {
            return false
        }
        switch (lhsThrows.type, rhsThrows.type) {
        case (nil, nil):
            return true
        case (let lhsError?, let rhsError?):
            return typeSyntaxMatches(lhsError, rhsError, allowExistentialUnwrap: true)
        default:
            return false
        }
    default:
        return false
    }
}

private func unwrapGrouping(_ type: TypeSyntax) -> TypeSyntax {
    if let tupleType = type.as(TupleTypeSyntax.self),
       tupleType.elements.count == 1,
       let element = tupleType.elements.first,
       element.inoutKeyword == nil,
       element.firstName == nil,
       element.secondName == nil,
       element.ellipsis == nil,
       !element.type.is(PackExpansionTypeSyntax.self) {
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

private func opaqueConstraint(of type: TypeSyntax) -> TypeSyntax? {
    guard let someOrAny = type.as(SomeOrAnyTypeSyntax.self),
          someOrAny.someOrAnySpecifier.tokenKind == .keyword(.some)
    else {
        return nil
    }

    return someOrAny.constraint
}

private func isValidOpaqueConstraint(_ constraint: TypeSyntax) -> Bool {
    let unwrapped = unwrapGrouping(constraint)
    if unwrapped.is(IdentifierTypeSyntax.self) || unwrapped.is(MemberTypeSyntax.self) {
        return isNominalExistentialConstraint(unwrapped)
    }
    if let suppressed = unwrapped.as(SuppressedTypeSyntax.self) {
        return isNominalExistentialConstraint(suppressed.type)
    }
    if let composition = unwrapped.as(CompositionTypeSyntax.self) {
        return composition.elements.allSatisfy { element in
            isValidOpaqueConstraint(element.type)
        }
    }

    return false
}

private func isValidExistentialConstraint(_ constraint: TypeSyntax) -> Bool {
    let unwrapped = unwrapGrouping(constraint)
    if unwrapped.is(IdentifierTypeSyntax.self) || unwrapped.is(MemberTypeSyntax.self) {
        return isNominalExistentialConstraint(unwrapped)
    }
    if let suppressed = unwrapped.as(SuppressedTypeSyntax.self) {
        return isNominalExistentialConstraint(suppressed.type)
    }
    if let metatype = unwrapped.as(MetatypeTypeSyntax.self) {
        return isValidExistentialConstraint(metatype.baseType)
    }
    if let composition = unwrapped.as(CompositionTypeSyntax.self) {
        return composition.elements.allSatisfy { element in
            isValidExistentialConstraint(element.type)
        }
    }

    return false
}

private func isNominalExistentialConstraint(_ type: TypeSyntax) -> Bool {
    var current = unwrapGrouping(type)
    guard optionalWrappedType(current) == nil else {
        return false
    }

    var walkedMember = false
    while let member = current.as(MemberTypeSyntax.self) {
        walkedMember = true
        current = unwrapGrouping(member.baseType)
    }

    if current.is(IdentifierTypeSyntax.self) {
        return true
    }

    guard walkedMember else {
        return false
    }

    return current.is(OptionalTypeSyntax.self)
        || current.is(ArrayTypeSyntax.self)
        || current.is(DictionaryTypeSyntax.self)
        || current.is(InlineArrayTypeSyntax.self)
}

private func standardOptionalWrappedType(_ type: TypeSyntax) -> TypeSyntax? {
    if let optionalType = type.as(OptionalTypeSyntax.self) {
        return optionalType.wrappedType
    }

    return optionalWrappedType(type)
}

private func optionalWrappedType(_ type: TypeSyntax) -> TypeSyntax? {
    if let identifierType = type.as(IdentifierTypeSyntax.self),
       let selector = moduleSelectorName(of: identifierType) as String??,
       selector == nil || selector == "Swift",
       identifierType.name.text == "Optional",
       let arguments = identifierType.genericArgumentClause?.arguments,
       arguments.count == 1,
       let argument = arguments.first,
       case .type(let wrappedType) = argument.argument {
        return wrappedType
    }

    guard let memberType = type.as(MemberTypeSyntax.self),
          moduleSelectorName(of: memberType) == nil,
          memberType.name.text == "Optional",
          let baseIdentifier = memberType.baseType.as(IdentifierTypeSyntax.self),
          moduleSelectorName(of: baseIdentifier) == nil,
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

private func moduleSelectorName(of identifierType: IdentifierTypeSyntax) -> String? {
    #if canImport(SwiftSyntax603)
    identifierType.moduleSelector?.moduleName.text
    #else
    nil
    #endif
}

private func moduleSelectorName(of memberType: MemberTypeSyntax) -> String? {
    #if canImport(SwiftSyntax603)
    memberType.moduleSelector?.moduleName.text
    #else
    nil
    #endif
}

private enum NominalSegmentArguments {
    case none
    case syntax(GenericArgumentClauseSyntax)
    case syntheticOptional(TypeSyntax)

    var isEmpty: Bool {
        if case .none = self {
            return true
        }
        return false
    }

    var singleTypeArgument: TypeSyntax? {
        switch self {
        case .none:
            return nil
        case .syntax(let clause):
            guard clause.arguments.count == 1,
                  let argument = clause.arguments.first,
                  case .type(let type) = argument.argument
            else {
                return nil
            }
            return type
        case .syntheticOptional(let wrappedType):
            return wrappedType
        }
    }
}

private struct NominalASTSegment {
    let moduleSelector: String?
    let name: String
    let arguments: NominalSegmentArguments

    var isUnqualifiedStandardOptional: Bool {
        moduleSelector == nil && name == "Optional" && arguments.singleTypeArgument != nil
    }

    var isSwiftQualifiedStandardOptional: Bool {
        moduleSelector == "Swift" && name == "Optional" && arguments.singleTypeArgument != nil
    }

    var isStandardOptional: Bool {
        isUnqualifiedStandardOptional || isSwiftQualifiedStandardOptional
    }

    var isPlainSwiftNamespace: Bool {
        moduleSelector == nil && name == "Swift" && arguments.isEmpty
    }
}

private struct MemberTypeChain {
    let nonNominalBase: TypeSyntax?
    let segments: [NominalASTSegment]
    let rootWasParenthesized: Bool
}

private func memberTypeChain(for type: TypeSyntax) -> MemberTypeChain? {
    var reversed: [NominalASTSegment] = []
    var current = type
    var currentWasParenthesized = false

    while true {
        if let memberType = current.as(MemberTypeSyntax.self) {
            reversed.append(
                NominalASTSegment(
                    moduleSelector: moduleSelectorName(of: memberType),
                    name: memberType.name.text,
                    arguments: memberType.genericArgumentClause.map { .syntax($0) } ?? .none
                )
            )
            let unwrappedBase = unwrapGrouping(memberType.baseType)
            currentWasParenthesized = unwrappedBase.id != memberType.baseType.id
            current = unwrappedBase
            continue
        }

        if let identifierType = current.as(IdentifierTypeSyntax.self) {
            reversed.append(
                NominalASTSegment(
                    moduleSelector: moduleSelectorName(of: identifierType),
                    name: identifierType.name.text,
                    arguments: identifierType.genericArgumentClause.map { .syntax($0) } ?? .none
                )
            )
            reversed.reverse()
            return MemberTypeChain(
                nonNominalBase: nil,
                segments: reversed,
                rootWasParenthesized: currentWasParenthesized
            )
        }

        if !reversed.isEmpty, let optionalType = current.as(OptionalTypeSyntax.self) {
            reversed.append(
                NominalASTSegment(
                    moduleSelector: nil,
                    name: "Optional",
                    arguments: .syntheticOptional(optionalType.wrappedType)
                )
            )
            reversed.reverse()
            return MemberTypeChain(
                nonNominalBase: nil,
                segments: reversed,
                rootWasParenthesized: false
            )
        }

        if !reversed.isEmpty {
            reversed.reverse()
            return MemberTypeChain(
                nonNominalBase: current,
                segments: reversed,
                rootWasParenthesized: false
            )
        }

        return nil
    }
}

private func memberTypeChainsMatch(
    _ lhs: MemberTypeChain,
    _ rhs: MemberTypeChain
) -> Bool {
    switch (lhs.nonNominalBase, rhs.nonNominalBase) {
    case (nil, nil):
        return nominalSegmentsMatch(lhs, rhs)
    case (let lhsBase?, let rhsBase?):
        guard lhs.segments.count == rhs.segments.count,
              typeSyntaxMatches(lhsBase, rhsBase, allowExistentialUnwrap: false)
        else {
            return false
        }
        return zip(lhs.segments, rhs.segments).allSatisfy { lhsSegment, rhsSegment in
            lhsSegment.moduleSelector == rhsSegment.moduleSelector
                && lhsSegment.name == rhsSegment.name
                && nominalSegmentArgumentsMatch(lhsSegment.arguments, rhsSegment.arguments)
        }
    default:
        return false
    }
}

private func expandLeadingModuleSelector(
    _ segments: [NominalASTSegment]
) -> (segments: [NominalASTSegment], hadLeadingSelector: Bool) {
    guard let first = segments.first, let selector = first.moduleSelector else {
        return (segments, false)
    }

    var expanded: [NominalASTSegment] = []
    expanded.reserveCapacity(segments.count + 1)
    expanded.append(NominalASTSegment(moduleSelector: nil, name: selector, arguments: .none))
    expanded.append(
        NominalASTSegment(moduleSelector: nil, name: first.name, arguments: first.arguments)
    )
    expanded.append(contentsOf: segments.dropFirst())
    return (expanded, true)
}

private func canonicalizeLeadingStandardOptional(
    _ segments: [NominalASTSegment]
) -> [NominalASTSegment] {
    guard segments.count >= 2,
          segments[0].isPlainSwiftNamespace,
          segments[1].isUnqualifiedStandardOptional
    else {
        return segments
    }

    var normalized: [NominalASTSegment] = []
    normalized.reserveCapacity(segments.count - 1)
    normalized.append(
        NominalASTSegment(
            moduleSelector: "Swift",
            name: "Optional",
            arguments: segments[1].arguments
        )
    )
    normalized.append(contentsOf: segments.dropFirst(2))
    return normalized
}

private func nominalSegmentsMatch(
    _ lhs: MemberTypeChain,
    _ rhs: MemberTypeChain
) -> Bool {
    let (expandedLHS, lhsHadLeadingSelector) = expandLeadingModuleSelector(lhs.segments)
    let (expandedRHS, rhsHadLeadingSelector) = expandLeadingModuleSelector(rhs.segments)
    let lhsHasParenthesizedTypeOwner = lhs.rootWasParenthesized && !lhsHadLeadingSelector
    let rhsHasParenthesizedTypeOwner = rhs.rootWasParenthesized && !rhsHadLeadingSelector

    if (lhsHadLeadingSelector && rhsHasParenthesizedTypeOwner)
        || (rhsHadLeadingSelector && lhsHasParenthesizedTypeOwner) {
        return false
    }

    let lhsSegments = lhsHasParenthesizedTypeOwner
        ? expandedLHS
        : canonicalizeLeadingStandardOptional(expandedLHS)
    let rhsSegments = rhsHasParenthesizedTypeOwner
        ? expandedRHS
        : canonicalizeLeadingStandardOptional(expandedRHS)

    guard rhsSegments.count <= lhsSegments.count else {
        return false
    }

    let droppedPrefixCount = lhsSegments.count - rhsSegments.count
    let droppedPrefix = lhsSegments.prefix(droppedPrefixCount)
    guard droppedPrefix.allSatisfy({ $0.arguments.isEmpty && $0.moduleSelector == nil }) else {
        return false
    }

    if !droppedPrefix.isEmpty, rhsHadLeadingSelector || rhsSegments[0].isStandardOptional {
        return false
    }

    for (index, (lhsSegment, rhsSegment)) in zip(lhsSegments.suffix(rhsSegments.count), rhsSegments).enumerated() {
        guard lhsSegment.name == rhsSegment.name else {
            return false
        }

        if index == 0 && lhsSegment.isStandardOptional && rhsSegment.isStandardOptional {
            // Standard Optional matches symmetrically across Optional<T>, Swift.Optional<T>,
            // Swift::Optional<T>, and T? bases.
        } else {
            guard lhsSegment.moduleSelector == rhsSegment.moduleSelector else {
                return false
            }
        }

        guard nominalSegmentArgumentsMatch(lhsSegment.arguments, rhsSegment.arguments) else {
            return false
        }
    }

    return true
}

private func nominalSegmentArgumentsMatch(
    _ lhs: NominalSegmentArguments,
    _ rhs: NominalSegmentArguments
) -> Bool {
    switch (lhs, rhs) {
    case (.none, .none):
        return true
    case (.syntax(let lhsClause), .syntax(let rhsClause)):
        guard lhsClause.arguments.count == rhsClause.arguments.count else {
            return false
        }
        for (lhsArgument, rhsArgument) in zip(lhsClause.arguments, rhsClause.arguments) {
            guard genericArgumentMatches(lhsArgument.argument, rhsArgument.argument) else {
                return false
            }
        }
        return true
    case (.syntheticOptional(let lhsWrapped), _):
        guard let rhsWrapped = rhs.singleTypeArgument else {
            return false
        }
        return typeSyntaxMatches(lhsWrapped, rhsWrapped, allowExistentialUnwrap: true)
    case (_, .syntheticOptional(let rhsWrapped)):
        guard let lhsWrapped = lhs.singleTypeArgument else {
            return false
        }
        return typeSyntaxMatches(lhsWrapped, rhsWrapped, allowExistentialUnwrap: true)
    default:
        return false
    }
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
