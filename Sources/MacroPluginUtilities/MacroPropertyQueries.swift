import SwiftSyntax

/// The identifier and exact binding for a stored property with an initializer.
public struct InlineInitializedStoredProperty {
    /// The binding's identifier pattern.
    public let identifier: IdentifierPatternSyntax

    /// The binding that owns the initializer.
    public let binding: PatternBindingSyntax

    /// Creates a projection from one initialized property binding.
    public init(identifier: IdentifierPatternSyntax, binding: PatternBindingSyntax) {
        self.identifier = identifier
        self.binding = binding
    }
}

/// Returns whether a class declares a stored instance `let` with the expected name and normalized type.
public func hasStoredLetProperty(
    named propertyName: String,
    typeNamed typeName: String,
    in classDecl: ClassDeclSyntax
) -> Bool {
    guard let expectedPattern = ExpectedTypePattern(parsing: typeName) else {
        return false
    }

    return hasStoredLetProperty(named: propertyName, typePattern: expectedPattern, in: classDecl)
}

func hasStoredLetProperty(
    named propertyName: String,
    typePattern expectedPattern: ExpectedTypePattern,
    in classDecl: ClassDeclSyntax
) -> Bool {
    classDecl.memberBlock.members.contains { member in
        guard let variableDecl = member.decl.as(VariableDeclSyntax.self),
              variableDecl.bindingSpecifier.tokenKind == .keyword(.let),
              isInstanceVariable(variableDecl)
        else {
            return false
        }

        return variableDecl.bindings.contains { binding in
            guard binding.accessorBlock == nil,
                  let identifierPattern = binding.pattern.as(IdentifierPatternSyntax.self),
                  identifierPattern.identifier.text == propertyName,
                  let typeAnnotation = binding.typeAnnotation
            else {
                return false
            }

            return expectedPattern.matches(typeAnnotation.type)
        }
    }
}

/// Returns the first stored instance-property binding with the expected name and an initializer.
public func inlineInitializedStoredProperty(
    named propertyName: String,
    in classDecl: ClassDeclSyntax
) -> InlineInitializedStoredProperty? {
    classDecl.memberBlock.members.lazy.compactMap { member -> InlineInitializedStoredProperty? in
        guard let variableDecl = member.decl.as(VariableDeclSyntax.self),
              isInstanceVariable(variableDecl)
        else {
            return nil
        }

        return variableDecl.bindings.lazy.compactMap { binding in
            guard binding.accessorBlock == nil,
                  binding.initializer != nil,
                  let identifier = binding.pattern.as(IdentifierPatternSyntax.self),
                  identifier.identifier.text == propertyName
            else {
                return nil
            }
            return InlineInitializedStoredProperty(identifier: identifier, binding: binding)
        }
        .first
    }
    .first
}

/// Returns unmanaged, uninitialized stored instance-property names in source order.
public func unsupportedUninitializedStoredProperties(
    in classDecl: ClassDeclSyntax,
    excluding managedPropertyNames: Set<String>
) -> [String] {
    // Validation runs against the source declaration before member synthesis.
    // Macro-generated members are intentionally excluded from this check.
    classDecl.memberBlock.members.flatMap { member -> [String] in
        guard let variableDecl = member.decl.as(VariableDeclSyntax.self),
              isInstanceVariable(variableDecl)
        else {
            return []
        }

        return variableDecl.bindings.compactMap { binding in
            guard binding.accessorBlock == nil,
                  binding.initializer == nil,
                  let identifierPattern = binding.pattern.as(IdentifierPatternSyntax.self)
            else {
                return nil
            }

            let propertyName = identifierPattern.identifier.text
            return managedPropertyNames.contains(propertyName) ? nil : propertyName
        }
    }
}

/// Returns whether a class has an initializer with exactly one matching labelled parameter.
public func hasConflictingInitializer(
    parameterLabel: String,
    parameterType: String,
    in classDecl: ClassDeclSyntax
) -> Bool {
    guard let expectedPattern = ExpectedTypePattern(parsing: parameterType) else {
        return false
    }

    return hasConflictingInitializer(
        parameterLabel: parameterLabel,
        parameterTypePattern: expectedPattern,
        in: classDecl
    )
}

func hasConflictingInitializer(
    parameterLabel: String,
    parameterTypePattern expectedPattern: ExpectedTypePattern,
    in classDecl: ClassDeclSyntax
) -> Bool {
    classDecl.memberBlock.members.contains { member in
        guard let initializerDecl = member.decl.as(InitializerDeclSyntax.self) else {
            return false
        }

        let parameters = initializerDecl.signature.parameterClause.parameters
        guard parameters.count == 1,
              let parameter = parameters.first,
              parameter.firstName.text == parameterLabel
        else {
            return false
        }

        return expectedPattern.matches(parameter.type)
    }
}
