import SwiftSyntax

public func hasStoredLetProperty(
    named propertyName: String,
    typeNamed typeName: String,
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

            return typeMatches(typeAnnotation.type, expectedTypeName: typeName)
        }
    }
}

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

public func hasConflictingInitializer(
    parameterLabel: String,
    parameterType: String,
    in classDecl: ClassDeclSyntax
) -> Bool {
    classDecl.memberBlock.members.contains { member in
        guard let initializerDecl = member.decl.as(InitializerDeclSyntax.self) else {
            return false
        }

        let parameters = initializerDecl.signature.parameterClause.parameters
        guard parameters.count == 1, let parameter = parameters.first else {
            return false
        }

        let hasExpectedLabel = parameter.firstName.text == parameterLabel
        let hasExpectedType = typeMatches(parameter.type, expectedTypeName: parameterType)
        return hasExpectedLabel && hasExpectedType
    }
}
