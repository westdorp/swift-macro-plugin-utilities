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
    guard let expectedPattern = ExpectedTypePattern(
        parsing: expectedTypeName,
        allowLegacyClassRestriction: true
    ) else {
        return false
    }

    return expectedPattern.matches(type)
}

struct ExpectedTypePattern: Sendable {
    private let root: ExpectedTypeNode

    init?(parsing text: String, allowLegacyClassRestriction: Bool = false) {
        guard let trimmed = trimmedNonEmpty(text) else {
            return nil
        }

        if allowLegacyClassRestriction, trimmed == "class" {
            self.root = .classRestriction
            return
        }

        guard let parsed = parseExpectedType(trimmed),
              let compiled = compileExpectedType(parsed, mode: .normal)
        else {
            return nil
        }

        self.root = compiled
    }

    func matches(_ type: TypeSyntax) -> Bool {
        guard !type.hasError else {
            return false
        }

        return typeSyntaxMatches(type, root, mode: .normal)
    }
}

private func trimmedNonEmpty(_ text: String) -> String? {
    guard let firstNonWhitespace = text.firstIndex(where: { !$0.isWhitespace }),
          let lastNonWhitespace = text.lastIndex(where: { !$0.isWhitespace })
    else {
        return nil
    }

    return String(text[firstNonWhitespace...lastNonWhitespace])
}

private func parseExpectedType(_ trimmed: String) -> TypeSyntax? {
    var parser = Parser(trimmed)
    let parsed = TypeSyntax.parse(from: &parser)
    guard !parsed.hasError, parsed.totalLength.utf8Length == trimmed.utf8.count else {
        return nil
    }

    return parsed
}

private enum TypeMatchMode {
    case normal
    case exact
    case existentialConstraint
    case opaqueOrCompositionConstraint
    case nominalConstraint
}

private indirect enum ExpectedTypeNode: Sendable {
    case existential(ExpectedTypeNode)
    case opaque(ExpectedTypeNode)
    case optional(ExpectedTypeNode)
    case iuo(ExpectedTypeNode)
    case metatype(specifier: String, base: ExpectedTypeNode)
    case composition([ExpectedTypeNode])
    case array(ExpectedTypeNode)
    case dictionary(key: ExpectedTypeNode, value: ExpectedTypeNode)
    case inlineArray(count: ExpectedGenericArgument, element: ExpectedGenericArgument)
    case tuple([ExpectedTupleElement])
    case function(
        parameters: [ExpectedFunctionParameter],
        asyncSpecifier: String?,
        throwsClause: ExpectedThrowsClause?,
        returnType: ExpectedTypeNode
    )
    case attributed(
        specifiers: [TokenKind],
        attributes: [TokenKind],
        lateSpecifiers: [TokenKind],
        base: ExpectedTypeNode
    )
    case packExpansion(ExpectedTypeNode)
    case packElement(ExpectedTypeNode)
    case suppressed(ExpectedTypeNode)
    case classRestriction
    case memberChain(ExpectedMemberChain)
    case tokens([TokenKind])
}

private struct ExpectedTupleElement: Sendable {
    let firstName: String?
    let secondName: String?
    let isVariadic: Bool
    let type: ExpectedTypeNode
}

private struct ExpectedFunctionParameter: Sendable {
    let isVariadic: Bool
    let type: ExpectedTypeNode
}

private struct ExpectedThrowsClause: Sendable {
    let throwsSpecifier: String
    let errorType: ExpectedTypeNode?
}

private enum ExpectedGenericArgument: Sendable {
    case type(ExpectedTypeNode)
    case expr([TokenKind])
}

private enum ExpectedSegmentArguments: Sendable {
    case none
    case arguments([ExpectedGenericArgument])
    case syntheticOptional(ExpectedTypeNode)

    var singleTypeArgument: ExpectedTypeNode? {
        switch self {
        case .none:
            nil
        case .arguments(let arguments):
            if arguments.count == 1, case .type(let type) = arguments[0] {
                type
            } else {
                nil
            }
        case .syntheticOptional(let wrappedType):
            wrappedType
        }
    }
}

private struct ExpectedNominalSegment: Sendable {
    let moduleSelector: String?
    let name: String
    let arguments: ExpectedSegmentArguments

    var isUnqualifiedStandardOptional: Bool {
        moduleSelector == nil && name == "Optional" && arguments.singleTypeArgument != nil
    }

    var isSwiftQualifiedStandardOptional: Bool {
        moduleSelector == "Swift" && name == "Optional" && arguments.singleTypeArgument != nil
    }

    var isStandardOptional: Bool {
        isUnqualifiedStandardOptional || isSwiftQualifiedStandardOptional
    }
}

private struct ExpectedMemberChain: Sendable {
    let nonNominalBase: ExpectedTypeNode?
    let rawExpandedCount: Int
    let segments: [ExpectedNominalSegment]
    let hadLeadingSelector: Bool
    let hasParenthesizedTypeOwner: Bool
}

private func compileExpectedType(
    _ type: TypeSyntax,
    mode: TypeMatchMode
) -> ExpectedTypeNode? {
    let unwrapped = unwrapGrouping(type)

    switch mode {
    case .existentialConstraint, .opaqueOrCompositionConstraint, .nominalConstraint:
        return compileExpectedConstraintType(unwrapped, mode: mode)
    case .normal, .exact:
        break
    }

    if let existential = existentialConstraint(of: unwrapped) {
        guard let compiledConstraint = compileExpectedType(existential, mode: .existentialConstraint) else {
            return nil
        }
        return .existential(compiledConstraint)
    }

    if let opaque = opaqueConstraint(of: unwrapped) {
        guard let compiledConstraint = compileExpectedType(opaque, mode: .opaqueOrCompositionConstraint) else {
            return nil
        }
        return .opaque(compiledConstraint)
    }

    if let wrapped = standardOptionalWrappedType(unwrapped) {
        guard let compiledWrapped = compileExpectedType(wrapped, mode: .normal) else {
            return nil
        }
        return .optional(compiledWrapped)
    }

    if let iuo = unwrapped.as(ImplicitlyUnwrappedOptionalTypeSyntax.self) {
        guard let compiledWrapped = compileExpectedType(iuo.wrappedType, mode: .normal) else {
            return nil
        }
        return .iuo(compiledWrapped)
    }

    if let metatype = unwrapped.as(MetatypeTypeSyntax.self) {
        guard let compiledBase = compileExpectedType(metatype.baseType, mode: .exact) else {
            return nil
        }
        return .metatype(specifier: metatype.metatypeSpecifier.text, base: compiledBase)
    }

    if let composition = unwrapped.as(CompositionTypeSyntax.self) {
        return compileExpectedComposition(composition)
    }

    if let array = unwrapped.as(ArrayTypeSyntax.self) {
        guard let compiledElement = compileExpectedType(array.element, mode: .normal) else {
            return nil
        }
        return .array(compiledElement)
    }

    if let dictionary = unwrapped.as(DictionaryTypeSyntax.self) {
        guard let compiledKey = compileExpectedType(dictionary.key, mode: .normal),
              let compiledValue = compileExpectedType(dictionary.value, mode: .normal)
        else {
            return nil
        }
        return .dictionary(key: compiledKey, value: compiledValue)
    }

    if let inlineArray = unwrapped.as(InlineArrayTypeSyntax.self) {
        guard let compiledCount = compileExpectedGenericArgument(inlineArray.count.argument),
              let compiledElement = compileExpectedGenericArgument(inlineArray.element.argument)
        else {
            return nil
        }
        return .inlineArray(count: compiledCount, element: compiledElement)
    }

    if let tuple = unwrapped.as(TupleTypeSyntax.self) {
        var elements: [ExpectedTupleElement] = []
        elements.reserveCapacity(tuple.elements.count)
        for element in tuple.elements {
            guard let compiledType = compileExpectedTupleElementType(element) else {
                return nil
            }
            elements.append(
                ExpectedTupleElement(
                    firstName: element.firstName?.text,
                    secondName: element.secondName?.text,
                    isVariadic: element.ellipsis != nil,
                    type: compiledType
                )
            )
        }
        return .tuple(elements)
    }

    if let function = unwrapped.as(FunctionTypeSyntax.self) {
        var parameters: [ExpectedFunctionParameter] = []
        parameters.reserveCapacity(function.parameters.count)
        for parameter in function.parameters {
            guard isValidFunctionParameterLabel(parameter),
                  let compiledType = compileExpectedTupleElementType(parameter)
            else {
                return nil
            }
            parameters.append(
                ExpectedFunctionParameter(
                    isVariadic: parameter.ellipsis != nil,
                    type: compiledType
                )
            )
        }

        let throwsClause: ExpectedThrowsClause?
        if let rawThrows = function.effectSpecifiers?.throwsClause {
            if let rawErrorType = rawThrows.type {
                guard let compiledErrorType = compileExpectedType(rawErrorType, mode: .normal) else {
                    return nil
                }
                throwsClause = ExpectedThrowsClause(
                    throwsSpecifier: rawThrows.throwsSpecifier.text,
                    errorType: compiledErrorType
                )
            } else {
                throwsClause = ExpectedThrowsClause(
                    throwsSpecifier: rawThrows.throwsSpecifier.text,
                    errorType: nil
                )
            }
        } else {
            throwsClause = nil
        }

        guard let compiledReturnType = compileExpectedType(function.returnClause.type, mode: .normal) else {
            return nil
        }

        return .function(
            parameters: parameters,
            asyncSpecifier: function.effectSpecifiers?.asyncSpecifier?.text,
            throwsClause: throwsClause,
            returnType: compiledReturnType
        )
    }

    if let attributed = unwrapped.as(AttributedTypeSyntax.self) {
        guard let compiledBase = compileExpectedType(attributed.baseType, mode: mode) else {
            return nil
        }
        return .attributed(
            specifiers: normalizedTokens(attributed.specifiers),
            attributes: normalizedTokens(attributed.attributes),
            lateSpecifiers: normalizedTokens(attributed.lateSpecifiers),
            base: compiledBase
        )
    }

    if let packExpansion = unwrapped.as(PackExpansionTypeSyntax.self) {
        guard let compiledPattern = compileExpectedType(packExpansion.repetitionPattern, mode: .normal) else {
            return nil
        }
        return .packExpansion(compiledPattern)
    }

    if let packElement = unwrapped.as(PackElementTypeSyntax.self) {
        guard let compiledPack = compileExpectedType(packElement.pack, mode: .exact) else {
            return nil
        }
        return .packElement(compiledPack)
    }

    if let suppressed = unwrapped.as(SuppressedTypeSyntax.self) {
        guard let compiledInner = compileExpectedType(suppressed.type, mode: .nominalConstraint) else {
            return nil
        }
        return .suppressed(compiledInner)
    }

    if let chain = memberTypeChain(for: unwrapped) {
        guard let compiledChain = compileExpectedMemberChain(chain) else {
            return nil
        }
        return .memberChain(compiledChain)
    }

    return .tokens(normalizedTokens(unwrapped))
}

private func compileExpectedConstraintType(
    _ unwrapped: TypeSyntax,
    mode: TypeMatchMode
) -> ExpectedTypeNode? {
    if mode == .existentialConstraint,
       let metatype = unwrapped.as(MetatypeTypeSyntax.self),
       metatype.metatypeSpecifier.text == "Type" {
        guard let compiledBase = compileExpectedType(metatype.baseType, mode: .existentialConstraint) else {
            return nil
        }
        return .metatype(specifier: metatype.metatypeSpecifier.text, base: compiledBase)
    }

    if mode != .nominalConstraint,
       let composition = unwrapped.as(CompositionTypeSyntax.self) {
        return compileExpectedComposition(composition)
    }

    if mode != .nominalConstraint,
       let suppressed = unwrapped.as(SuppressedTypeSyntax.self) {
        guard let compiledInner = compileExpectedType(suppressed.type, mode: .nominalConstraint) else {
            return nil
        }
        return .suppressed(compiledInner)
    }

    guard standardOptionalWrappedType(unwrapped) == nil,
          let chain = memberTypeChain(for: unwrapped),
          isValidConstraintMemberBase(chain.nonNominalBase),
          let compiledChain = compileExpectedMemberChain(chain)
    else {
        return nil
    }

    return .memberChain(compiledChain)
}

private func compileExpectedComposition(
    _ composition: CompositionTypeSyntax
) -> ExpectedTypeNode? {
    var elements: [ExpectedTypeNode] = []
    elements.reserveCapacity(composition.elements.count)
    guard appendExpectedCompositionElements(composition, to: &elements) else {
        return nil
    }
    return .composition(elements)
}

private func appendExpectedCompositionElements(
    _ composition: CompositionTypeSyntax,
    to elements: inout [ExpectedTypeNode]
) -> Bool {
    for element in composition.elements {
        let unwrappedElement = unwrapGrouping(element.type)
        if let nestedComposition = unwrappedElement.as(CompositionTypeSyntax.self) {
            guard appendExpectedCompositionElements(nestedComposition, to: &elements) else {
                return false
            }
        } else {
            guard let compiledElement = compileExpectedType(
                unwrappedElement,
                mode: .opaqueOrCompositionConstraint
            ) else {
                return false
            }
            elements.append(compiledElement)
        }
    }
    return true
}

private func compileExpectedTupleElementType(
    _ element: TupleTypeElementSyntax
) -> ExpectedTypeNode? {
    guard let inoutKeyword = element.inoutKeyword else {
        return compileExpectedType(element.type, mode: .normal)
    }

    if let attributed = element.type.as(AttributedTypeSyntax.self) {
        guard let compiledBase = compileExpectedType(attributed.baseType, mode: .normal) else {
            return nil
        }
        return .attributed(
            specifiers: [inoutKeyword.tokenKind] + normalizedTokens(attributed.specifiers),
            attributes: normalizedTokens(attributed.attributes),
            lateSpecifiers: normalizedTokens(attributed.lateSpecifiers),
            base: compiledBase
        )
    }

    guard let compiledBase = compileExpectedType(element.type, mode: .normal) else {
        return nil
    }
    return .attributed(
        specifiers: [inoutKeyword.tokenKind],
        attributes: [],
        lateSpecifiers: [],
        base: compiledBase
    )
}

private func compileExpectedGenericArgument(
    _ argument: GenericArgumentSyntax.Argument
) -> ExpectedGenericArgument? {
    switch argument {
    case .type(let type):
        guard let compiledType = compileExpectedType(type, mode: .normal) else {
            return nil
        }
        return .type(compiledType)
    case .expr(let expr):
        return .expr(normalizedTokens(expr))
    }
}

private func compileExpectedMemberChain(
    _ chain: MemberTypeChain
) -> ExpectedMemberChain? {
    if let nonNominalBase = chain.nonNominalBase {
        guard let compiledBase = compileExpectedType(nonNominalBase, mode: .exact),
              let compiledSegments = compileExpectedSegments(chain.segments)
        else {
            return nil
        }
        return ExpectedMemberChain(
            nonNominalBase: compiledBase,
            rawExpandedCount: compiledSegments.count,
            segments: compiledSegments,
            hadLeadingSelector: false,
            hasParenthesizedTypeOwner: false
        )
    }

    let (expanded, hadLeadingSelector) = expandLeadingModuleSelector(chain.segments)
    let hasParenthesizedTypeOwner = chain.rootWasParenthesized && !hadLeadingSelector
    let canonical = hasParenthesizedTypeOwner
        ? expanded
        : canonicalizeLeadingStandardOptional(expanded)
    guard let compiledSegments = compileExpectedSegments(canonical) else {
        return nil
    }
    return ExpectedMemberChain(
        nonNominalBase: nil,
        rawExpandedCount: expanded.count,
        segments: compiledSegments,
        hadLeadingSelector: hadLeadingSelector,
        hasParenthesizedTypeOwner: hasParenthesizedTypeOwner
    )
}

private func compileExpectedSegments(
    _ segments: [NominalASTSegment]
) -> [ExpectedNominalSegment]? {
    var compiled: [ExpectedNominalSegment] = []
    compiled.reserveCapacity(segments.count)
    for segment in segments {
        let arguments: ExpectedSegmentArguments
        switch segment.arguments {
        case .none:
            arguments = .none
        case .syntax(let clause):
            var compiledArguments: [ExpectedGenericArgument] = []
            compiledArguments.reserveCapacity(clause.arguments.count)
            for argument in clause.arguments {
                guard let compiledArgument = compileExpectedGenericArgument(argument.argument) else {
                    return nil
                }
                compiledArguments.append(compiledArgument)
            }
            arguments = .arguments(compiledArguments)
        case .syntheticOptional(let wrappedType):
            guard let compiledWrapped = compileExpectedType(wrappedType, mode: .normal) else {
                return nil
            }
            arguments = .syntheticOptional(compiledWrapped)
        }
        compiled.append(
            ExpectedNominalSegment(
                moduleSelector: segment.moduleSelector,
                name: segment.name,
                arguments: arguments
            )
        )
    }
    return compiled
}

private func typeSyntaxMatches(
    _ actual: TypeSyntax,
    _ expected: ExpectedTypeNode,
    mode: TypeMatchMode
) -> Bool {
    let lhs = unwrapGrouping(actual)

    switch mode {
    case .existentialConstraint, .opaqueOrCompositionConstraint, .nominalConstraint:
        return constraintTypeSyntaxMatches(lhs, expected, mode: mode)
    case .normal:
        let lhsExistential = existentialConstraint(of: lhs)
        if case .existential(let expectedConstraint) = expected {
            if let lhsConstraint = lhsExistential {
                return typeSyntaxMatches(lhsConstraint, expectedConstraint, mode: .existentialConstraint)
            }
            return typeSyntaxMatches(lhs, expectedConstraint, mode: .existentialConstraint)
        }
        if let lhsConstraint = lhsExistential {
            return typeSyntaxMatches(lhsConstraint, expected, mode: .existentialConstraint)
        }
    case .exact:
        let lhsExistential = existentialConstraint(of: lhs)
        if case .existential(let expectedConstraint) = expected {
            guard let lhsConstraint = lhsExistential else {
                return false
            }
            return typeSyntaxMatches(lhsConstraint, expectedConstraint, mode: .existentialConstraint)
        }
        if lhsExistential != nil {
            return false
        }
    }

    switch expected {
    case .existential:
        return false
    case .opaque(let expectedConstraint):
        guard let lhsConstraint = opaqueConstraint(of: lhs) else {
            return false
        }
        return typeSyntaxMatches(lhsConstraint, expectedConstraint, mode: .opaqueOrCompositionConstraint)
    case .optional(let expectedWrapped):
        guard let lhsWrapped = standardOptionalWrappedType(lhs) else {
            return false
        }
        return typeSyntaxMatches(lhsWrapped, expectedWrapped, mode: .normal)
    case .iuo(let expectedWrapped):
        guard let lhsIUO = lhs.as(ImplicitlyUnwrappedOptionalTypeSyntax.self) else {
            return false
        }
        return typeSyntaxMatches(lhsIUO.wrappedType, expectedWrapped, mode: .normal)
    case .metatype(let expectedSpecifier, let expectedBase):
        guard let lhsMetatype = lhs.as(MetatypeTypeSyntax.self),
              lhsMetatype.metatypeSpecifier.text == expectedSpecifier
        else {
            return false
        }
        return typeSyntaxMatches(lhsMetatype.baseType, expectedBase, mode: .exact)
    case .composition(let expectedElements):
        guard let lhsComposition = lhs.as(CompositionTypeSyntax.self) else {
            return false
        }
        return compositionTypesMatch(lhsComposition, expectedElements)
    case .array(let expectedElement):
        guard let lhsArray = lhs.as(ArrayTypeSyntax.self) else {
            return false
        }
        return typeSyntaxMatches(lhsArray.element, expectedElement, mode: .normal)
    case .dictionary(let expectedKey, let expectedValue):
        guard let lhsDictionary = lhs.as(DictionaryTypeSyntax.self) else {
            return false
        }
        return typeSyntaxMatches(lhsDictionary.key, expectedKey, mode: .normal)
            && typeSyntaxMatches(lhsDictionary.value, expectedValue, mode: .normal)
    case .inlineArray(let expectedCount, let expectedElement):
        guard let lhsInlineArray = lhs.as(InlineArrayTypeSyntax.self) else {
            return false
        }
        return genericArgumentMatches(lhsInlineArray.count.argument, expectedCount)
            && genericArgumentMatches(lhsInlineArray.element.argument, expectedElement)
    case .tuple(let expectedElements):
        guard let lhsTuple = lhs.as(TupleTypeSyntax.self) else {
            return false
        }
        return tupleElementsMatch(lhsTuple.elements, expectedElements)
    case .function(let expectedParameters, let expectedAsync, let expectedThrows, let expectedReturnType):
        guard let lhsFunction = lhs.as(FunctionTypeSyntax.self) else {
            return false
        }
        return functionParametersMatch(lhsFunction.parameters, expectedParameters)
            && effectSpecifiersMatch(
                lhsFunction.effectSpecifiers,
                expectedAsync: expectedAsync,
                expectedThrows: expectedThrows
            )
            && typeSyntaxMatches(lhsFunction.returnClause.type, expectedReturnType, mode: .normal)
    case .attributed(let expectedSpecifiers, let expectedAttributes, let expectedLateSpecifiers, let expectedBase):
        guard let lhsAttributed = lhs.as(AttributedTypeSyntax.self),
              tokensMatch(lhsAttributed.specifiers, expected: expectedSpecifiers),
              tokensMatch(lhsAttributed.attributes, expected: expectedAttributes),
              tokensMatch(lhsAttributed.lateSpecifiers, expected: expectedLateSpecifiers)
        else {
            return false
        }
        return typeSyntaxMatches(lhsAttributed.baseType, expectedBase, mode: mode)
    case .packExpansion(let expectedPattern):
        guard let lhsPackExpansion = lhs.as(PackExpansionTypeSyntax.self) else {
            return false
        }
        return typeSyntaxMatches(lhsPackExpansion.repetitionPattern, expectedPattern, mode: .normal)
    case .packElement(let expectedPack):
        guard let lhsPackElement = lhs.as(PackElementTypeSyntax.self) else {
            return false
        }
        return typeSyntaxMatches(lhsPackElement.pack, expectedPack, mode: .exact)
    case .suppressed(let expectedInner):
        guard let lhsSuppressed = lhs.as(SuppressedTypeSyntax.self) else {
            return false
        }
        return typeSyntaxMatches(lhsSuppressed.type, expectedInner, mode: .nominalConstraint)
    case .classRestriction:
        return lhs.is(ClassRestrictionTypeSyntax.self)
    case .memberChain(let expectedChain):
        guard standardOptionalWrappedType(lhs) == nil,
              let lhsChain = memberTypeChain(for: lhs)
        else {
            return false
        }
        return memberTypeChainsMatch(lhsChain, expectedChain)
    case .tokens(let expectedTokens):
        guard opaqueConstraint(of: lhs) == nil,
              standardOptionalWrappedType(lhs) == nil,
              !lhs.is(ImplicitlyUnwrappedOptionalTypeSyntax.self),
              !lhs.is(MetatypeTypeSyntax.self),
              !lhs.is(CompositionTypeSyntax.self),
              !lhs.is(ArrayTypeSyntax.self),
              !lhs.is(DictionaryTypeSyntax.self),
              !lhs.is(InlineArrayTypeSyntax.self),
              !lhs.is(TupleTypeSyntax.self),
              !lhs.is(FunctionTypeSyntax.self),
              !lhs.is(AttributedTypeSyntax.self),
              !lhs.is(PackExpansionTypeSyntax.self),
              !lhs.is(PackElementTypeSyntax.self),
              !lhs.is(SuppressedTypeSyntax.self),
              !lhs.is(ClassRestrictionTypeSyntax.self),
              memberTypeChain(for: lhs) == nil
        else {
            return false
        }
        return tokensMatch(lhs, expected: expectedTokens)
    }
}

private func constraintTypeSyntaxMatches(
    _ lhs: TypeSyntax,
    _ expected: ExpectedTypeNode,
    mode: TypeMatchMode
) -> Bool {
    switch expected {
    case .metatype(let expectedSpecifier, let expectedBase):
        guard mode == .existentialConstraint,
              expectedSpecifier == "Type",
              let lhsMetatype = lhs.as(MetatypeTypeSyntax.self),
              lhsMetatype.metatypeSpecifier.text == "Type"
        else {
            return false
        }
        return typeSyntaxMatches(
            lhsMetatype.baseType,
            expectedBase,
            mode: .existentialConstraint
        )
    case .composition(let expectedElements):
        guard mode != .nominalConstraint,
              let lhsComposition = lhs.as(CompositionTypeSyntax.self)
        else {
            return false
        }
        return compositionTypesMatch(lhsComposition, expectedElements)
    case .suppressed(let expectedInner):
        guard mode != .nominalConstraint,
              let lhsSuppressed = lhs.as(SuppressedTypeSyntax.self)
        else {
            return false
        }
        return typeSyntaxMatches(
            lhsSuppressed.type,
            expectedInner,
            mode: .nominalConstraint
        )
    case .memberChain(let expectedChain):
        guard standardOptionalWrappedType(lhs) == nil,
              let lhsChain = memberTypeChain(for: lhs),
              isValidConstraintMemberBase(lhsChain.nonNominalBase)
        else {
            return false
        }
        return memberTypeChainsMatch(lhsChain, expectedChain)
    default:
        return false
    }
}

private func compositionTypesMatch(
    _ lhs: CompositionTypeSyntax,
    _ expectedElements: [ExpectedTypeNode]
) -> Bool {
    var index = 0
    guard matchCompositionElements(lhs, expectedElements: expectedElements, index: &index) else {
        return false
    }
    return index == expectedElements.count
}

private func matchCompositionElements(
    _ lhs: CompositionTypeSyntax,
    expectedElements: [ExpectedTypeNode],
    index: inout Int
) -> Bool {
    for element in lhs.elements {
        let unwrappedElement = unwrapGrouping(element.type)
        if let nestedComposition = unwrappedElement.as(CompositionTypeSyntax.self) {
            guard matchCompositionElements(
                nestedComposition,
                expectedElements: expectedElements,
                index: &index
            ) else {
                return false
            }
        } else {
            guard index < expectedElements.count,
                  typeSyntaxMatches(
                      unwrappedElement,
                      expectedElements[index],
                      mode: .opaqueOrCompositionConstraint
                  )
            else {
                return false
            }
            index += 1
        }
    }
    return true
}

private func isValidConstraintMemberBase(_ base: TypeSyntax?) -> Bool {
    guard let base else {
        return true
    }

    return base.is(ArrayTypeSyntax.self)
        || base.is(DictionaryTypeSyntax.self)
        || base.is(InlineArrayTypeSyntax.self)
}

private func tupleElementsMatch(
    _ lhs: TupleTypeElementListSyntax,
    _ expectedElements: [ExpectedTupleElement]
) -> Bool {
    guard lhs.count == expectedElements.count else {
        return false
    }

    return zip(lhs, expectedElements).allSatisfy { lElement, expectedElement in
        lElement.firstName?.text == expectedElement.firstName
            && lElement.secondName?.text == expectedElement.secondName
            && (lElement.ellipsis != nil) == expectedElement.isVariadic
            && tupleElementTypesMatch(lElement, expectedElement.type)
    }
}

private func functionParametersMatch(
    _ lhs: TupleTypeElementListSyntax,
    _ expectedParameters: [ExpectedFunctionParameter]
) -> Bool {
    guard lhs.count == expectedParameters.count else {
        return false
    }

    return zip(lhs, expectedParameters).allSatisfy { lElement, expectedParameter in
        isValidFunctionParameterLabel(lElement)
            && (lElement.ellipsis != nil) == expectedParameter.isVariadic
            && tupleElementTypesMatch(lElement, expectedParameter.type)
    }
}

private func tupleElementTypesMatch(
    _ lhs: TupleTypeElementSyntax,
    _ expected: ExpectedTypeNode
) -> Bool {
    guard let inoutKeyword = lhs.inoutKeyword else {
        return typeSyntaxMatches(lhs.type, expected, mode: .normal)
    }

    guard case .attributed(
        let expectedSpecifiers,
        let expectedAttributes,
        let expectedLateSpecifiers,
        let expectedBase
    ) = expected else {
        return false
    }

    if let attributed = lhs.type.as(AttributedTypeSyntax.self) {
        guard specifiersMatch(
            leading: inoutKeyword.tokenKind,
            list: attributed.specifiers,
            expected: expectedSpecifiers
        ),
              tokensMatch(attributed.attributes, expected: expectedAttributes),
              tokensMatch(attributed.lateSpecifiers, expected: expectedLateSpecifiers)
        else {
            return false
        }
        return typeSyntaxMatches(attributed.baseType, expectedBase, mode: .normal)
    }

    guard expectedSpecifiers == [inoutKeyword.tokenKind],
          expectedAttributes.isEmpty,
          expectedLateSpecifiers.isEmpty
    else {
        return false
    }
    return typeSyntaxMatches(lhs.type, expectedBase, mode: .normal)
}

private func specifiersMatch(
    leading: TokenKind,
    list: TypeSpecifierListSyntax,
    expected: [TokenKind]
) -> Bool {
    guard expected.first == leading else {
        return false
    }

    var index = 1
    for token in list.tokens(viewMode: .sourceAccurate) {
        guard index < expected.count, token.tokenKind == expected[index] else {
            return false
        }
        index += 1
    }

    return index == expected.count
}

private func isValidFunctionParameterLabel(_ element: TupleTypeElementSyntax) -> Bool {
    guard let firstName = element.firstName else {
        return true
    }

    return firstName.text == "_"
}

private func effectSpecifiersMatch(
    _ lhs: TypeEffectSpecifiersSyntax?,
    expectedAsync: String?,
    expectedThrows: ExpectedThrowsClause?
) -> Bool {
    guard lhs?.asyncSpecifier?.text == expectedAsync else {
        return false
    }

    switch (lhs?.throwsClause, expectedThrows) {
    case (nil, nil):
        return true
    case (let lhsThrows?, let rhsThrows?):
        guard lhsThrows.throwsSpecifier.text == rhsThrows.throwsSpecifier else {
            return false
        }
        switch (lhsThrows.type, rhsThrows.errorType) {
        case (nil, nil):
            return true
        case (let lhsError?, let rhsError?):
            return typeSyntaxMatches(lhsError, rhsError, mode: .normal)
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
    _ rhs: ExpectedMemberChain
) -> Bool {
    switch (lhs.nonNominalBase, rhs.nonNominalBase) {
    case (nil, nil):
        return nominalSegmentsMatch(lhs, rhs)
    case (let lhsBase?, let rhsBase?):
        guard lhs.segments.count == rhs.segments.count,
              typeSyntaxMatches(lhsBase, rhsBase, mode: .exact)
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
    _ rhs: ExpectedMemberChain
) -> Bool {
    let (expandedLHS, lhsHadLeadingSelector) = expandLeadingModuleSelector(lhs.segments)
    let lhsHasParenthesizedTypeOwner = lhs.rootWasParenthesized && !lhsHadLeadingSelector

    if expandedLHS.count == rhs.rawExpandedCount,
       (lhsHadLeadingSelector && rhs.hasParenthesizedTypeOwner)
        || (rhs.hadLeadingSelector && lhsHasParenthesizedTypeOwner) {
        return false
    }

    let lhsSegments = lhsHasParenthesizedTypeOwner
        ? expandedLHS
        : canonicalizeLeadingStandardOptional(expandedLHS)
    let rhsSegments = rhs.segments

    guard rhsSegments.count <= lhsSegments.count else {
        return false
    }

    let droppedPrefixCount = lhsSegments.count - rhsSegments.count
    let droppedPrefix = lhsSegments.prefix(droppedPrefixCount)
    guard droppedPrefix.allSatisfy({ $0.arguments.isEmpty && $0.moduleSelector == nil }) else {
        return false
    }

    if !droppedPrefix.isEmpty, rhs.hadLeadingSelector || rhsSegments[0].isStandardOptional {
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
    _ rhs: ExpectedSegmentArguments
) -> Bool {
    switch (lhs, rhs) {
    case (.none, .none):
        return true
    case (.syntax(let lhsClause), .arguments(let rhsArguments)):
        guard lhsClause.arguments.count == rhsArguments.count else {
            return false
        }
        for (lhsArgument, rhsArgument) in zip(lhsClause.arguments, rhsArguments) {
            guard genericArgumentMatches(lhsArgument.argument, rhsArgument) else {
                return false
            }
        }
        return true
    case (.syntheticOptional(let lhsWrapped), _):
        guard let rhsWrapped = rhs.singleTypeArgument else {
            return false
        }
        return typeSyntaxMatches(lhsWrapped, rhsWrapped, mode: .normal)
    case (_, .syntheticOptional(let rhsWrapped)):
        guard let lhsWrapped = lhs.singleTypeArgument else {
            return false
        }
        return typeSyntaxMatches(lhsWrapped, rhsWrapped, mode: .normal)
    default:
        return false
    }
}

private func genericArgumentMatches(
    _ actual: GenericArgumentSyntax.Argument,
    _ expected: ExpectedGenericArgument
) -> Bool {
    switch (actual, expected) {
    case (.type(let actualType), .type(let expectedType)):
        typeSyntaxMatches(actualType, expectedType, mode: .normal)
    case (.expr(let actualExpr), .expr(let expectedExprTokens)):
        tokensMatch(actualExpr, expected: expectedExprTokens)
    default:
        false
    }
}

private func normalizedTokens(_ node: some SyntaxProtocol) -> [TokenKind] {
    node.tokens(viewMode: .sourceAccurate).map(\.tokenKind)
}

private func tokensMatch(_ node: some SyntaxProtocol, expected: [TokenKind]) -> Bool {
    var index = 0
    for token in node.tokens(viewMode: .sourceAccurate) {
        guard index < expected.count, token.tokenKind == expected[index] else {
            return false
        }
        index += 1
    }

    return index == expected.count
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
