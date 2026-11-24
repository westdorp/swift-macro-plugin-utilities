import SwiftSyntax
import SwiftSyntaxMacros

/// Consumer-supplied wording and identity for attached-class validation.
public struct MacroAttachedClassRequirements: Sendable {
    /// Stable identifiers for every validation failure.
    public struct DiagnosticIDs: Sendable {
        let classOnly: String
        let mainActorRequired: String
        let storedPropertyRequired: String
        let initializerConflict: String

        /// Creates the complete diagnostic identity set.
        public init(
            classOnly: String,
            mainActorRequired: String,
            storedPropertyRequired: String,
            initializerConflict: String
        ) {
            self.classOnly = classOnly
            self.mainActorRequired = mainActorRequired
            self.storedPropertyRequired = storedPropertyRequired
            self.initializerConflict = initializerConflict
        }
    }

    let attributeName: String
    let exampleClassName: String
    let lifecycleOwnershipReason: String
    let mainActorReason: String
    let storedPropertyName: String
    let storedPropertyTypeName: String
    let storedPropertyReason: String
    let initializerReason: String
    let diagnosticDomain: String
    let diagnosticIDs: DiagnosticIDs

    /// Creates an immutable validation and diagnostic contract.
    public init(
        attributeName: String,
        exampleClassName: String,
        lifecycleOwnershipReason: String,
        mainActorReason: String,
        storedPropertyName: String,
        storedPropertyTypeName: String,
        storedPropertyReason: String,
        initializerReason: String,
        diagnosticDomain: String,
        diagnosticIDs: DiagnosticIDs
    ) {
        self.attributeName = attributeName
        self.exampleClassName = exampleClassName
        self.lifecycleOwnershipReason = lifecycleOwnershipReason
        self.mainActorReason = mainActorReason
        self.storedPropertyName = storedPropertyName
        self.storedPropertyTypeName = storedPropertyTypeName
        self.storedPropertyReason = storedPropertyReason
        self.initializerReason = initializerReason
        self.diagnosticDomain = diagnosticDomain
        self.diagnosticIDs = diagnosticIDs
    }
}

/// A syntactic contract that an attached class can satisfy.
public enum MacroAttachedClassRequirement: Sendable {
    case finalClass
    case mainActorIsolation
    case storedLetProperty
    case initializerAvailability
}

/// Validates an attached class against consumer-supplied requirements.
public struct MacroAttachedClassValidator {
    /// The parsed class declaration under validation.
    public let classDeclaration: ClassDeclSyntax

    private let requirements: MacroAttachedClassRequirements

    /// Creates a validator for a known class declaration.
    public init(
        classDeclaration: ClassDeclSyntax,
        requirements: MacroAttachedClassRequirements
    ) {
        self.classDeclaration = classDeclaration
        self.requirements = requirements
    }

    /// Parses a declaration group as a class or diagnoses the class-only contract.
    public init?(
        validating declaration: some DeclGroupSyntax,
        requirements: MacroAttachedClassRequirements,
        in context: some MacroExpansionContext
    ) {
        guard let classDeclaration = declaration.as(ClassDeclSyntax.self) else {
            context.diagnose(
                Syntax(declaration),
                domain: requirements.diagnosticDomain,
                id: requirements.diagnosticIDs.classOnly,
                what: "\(requirements.attributeName) can only be applied to a final class.",
                why: requirements.lifecycleOwnershipReason,
                how: "Apply \(requirements.attributeName) to a declaration like '@MainActor final class \(requirements.exampleClassName) { let \(requirements.storedPropertyName): \(requirements.storedPropertyTypeName) }'."
            )
            return nil
        }

        self.init(classDeclaration: classDeclaration, requirements: requirements)
    }

    /// Diagnoses one unsatisfied requirement and returns whether it is satisfied.
    public func validate(
        _ requirement: MacroAttachedClassRequirement,
        in context: some MacroExpansionContext
    ) -> Bool {
        let className = Syntax(classDeclaration.name)
        switch requirement {
        case .finalClass:
            switch finalClassValidationState(for: classDeclaration) {
            case .validFinalClass:
                return true
            case .openClass(let alreadyFinal):
                let replacement = alreadyFinal ? "public" : "public final"
                let removal = alreadyFinal
                    ? "remove both 'final' and \(requirements.attributeName)"
                    : "remove \(requirements.attributeName)"
                context.diagnose(
                    className,
                    domain: requirements.diagnosticDomain,
                    id: requirements.diagnosticIDs.classOnly,
                    what: "\(requirements.attributeName) cannot be applied to an 'open' class.",
                    why: requirements.lifecycleOwnershipReason,
                    how: "Replace 'open' with '\(replacement)', change any 'open' members to 'public', update or remove any subclasses, or \(removal)."
                )
            case .finalClassWithOpenMembers(let hasNestedClasses):
                let how = hasNestedClasses
                    ? "Change any 'open' members to 'public', review nested or local classes, and update any subclassing so they are valid on a 'final' class."
                    : "Change any 'open' members to 'public' so they are valid on a 'final' class."
                context.diagnose(
                    className,
                    domain: requirements.diagnosticDomain,
                    id: requirements.diagnosticIDs.classOnly,
                    what: "\(requirements.attributeName) cannot accept a 'final' class that contains 'open' member declarations.",
                    why: "Swift forbids 'open' members on a 'final' class.",
                    how: how
                )
            case .nonFinalWithOpenMembers(let hasNestedClasses):
                let how = hasNestedClasses
                    ? "Change any 'open' members to 'public', review nested or local classes and update any subclassing, and add the 'final' modifier manually."
                    : "Change any 'open' members to 'public' before adding 'final'."
                context.diagnose(
                    className,
                    domain: requirements.diagnosticDomain,
                    id: requirements.diagnosticIDs.classOnly,
                    what: "\(requirements.attributeName) can only be applied to a final class.",
                    why: requirements.lifecycleOwnershipReason,
                    how: how
                )
            case .nestedClasses:
                context.diagnose(
                    className,
                    domain: requirements.diagnosticDomain,
                    id: requirements.diagnosticIDs.classOnly,
                    what: "\(requirements.attributeName) can only be applied to a final class.",
                    why: requirements.lifecycleOwnershipReason,
                    how: "Review nested or local classes, update any subclassing, and add the 'final' modifier manually."
                )
            case .fixable:
                let fixIts = [
                    makeAddFinalFixIt(
                        for: classDeclaration,
                        fixItMessage: MacroFixItMessage(
                            "Add 'final' modifier",
                            domain: requirements.diagnosticDomain
                        )
                    )
                ]
                context.diagnose(
                    className,
                    domain: requirements.diagnosticDomain,
                    id: requirements.diagnosticIDs.classOnly,
                    what: "\(requirements.attributeName) can only be applied to a final class.",
                    why: requirements.lifecycleOwnershipReason,
                    how: "Confirm no external declaration subclasses this type, then add the 'final' modifier to this class declaration.",
                    fixIts: fixIts
                )
            }
            return false
        case .mainActorIsolation:
            guard !satisfies(.mainActorIsolation) else {
                return true
            }
            let fixIts = [
                makeAddMainActorFixIt(
                    for: classDeclaration,
                    fixItMessage: MacroFixItMessage(
                        "Add '@MainActor' attribute",
                        domain: requirements.diagnosticDomain
                    )
                )
            ]
            context.diagnose(
                className,
                domain: requirements.diagnosticDomain,
                id: requirements.diagnosticIDs.mainActorRequired,
                what: "\(requirements.attributeName) requires @MainActor isolation.",
                why: requirements.mainActorReason,
                how: "Annotate the type with '@MainActor'.",
                fixIts: fixIts
            )
            return false
        case .storedLetProperty:
            guard !satisfies(.storedLetProperty) else {
                return true
            }
            context.diagnose(
                className,
                domain: requirements.diagnosticDomain,
                id: requirements.diagnosticIDs.storedPropertyRequired,
                what: "\(requirements.attributeName) requires a stored instance property 'let \(requirements.storedPropertyName): \(requirements.storedPropertyTypeName)'.",
                why: requirements.storedPropertyReason,
                how: "Add 'let \(requirements.storedPropertyName): \(requirements.storedPropertyTypeName)'."
            )
            return false
        case .initializerAvailability:
            guard !satisfies(.initializerAvailability) else {
                return true
            }
            let initializer = "init(\(requirements.storedPropertyName):)"
            context.diagnose(
                className,
                domain: requirements.diagnosticDomain,
                id: requirements.diagnosticIDs.initializerConflict,
                what: "\(requirements.attributeName) cannot synthesize '\(initializer)' because it is already declared.",
                why: requirements.initializerReason,
                how: "Remove the custom '\(initializer)' or remove \(requirements.attributeName) and manage wiring manually."
            )
            return false
        }
    }

    /// Diagnoses every unsatisfied requested contract.
    public func validate(
        _ requiredContracts: [MacroAttachedClassRequirement],
        in context: some MacroExpansionContext
    ) -> Bool {
        requiredContracts
            .map { validate($0, in: context) }
            .allSatisfy { $0 }
    }

    /// Returns whether the class satisfies one requirement.
    public func satisfies(_ requirement: MacroAttachedClassRequirement) -> Bool {
        switch requirement {
        case .finalClass:
            finalClassValidationState(for: classDeclaration).isValidFinalClass
        case .mainActorIsolation:
            hasAttribute(named: "MainActor", in: classDeclaration.attributes)
        case .storedLetProperty:
            hasStoredLetProperty(
                named: requirements.storedPropertyName,
                typeNamed: requirements.storedPropertyTypeName,
                in: classDeclaration
            )
        case .initializerAvailability:
            !hasConflictingInitializer(
                parameterLabel: requirements.storedPropertyName,
                parameterType: requirements.storedPropertyTypeName,
                in: classDeclaration
            )
        }
    }

    /// Returns whether the class satisfies every requested contract.
    public func satisfies(_ requiredContracts: [MacroAttachedClassRequirement]) -> Bool {
        requiredContracts.allSatisfy { satisfies($0) }
    }
}

private enum FinalClassValidationState {
    case validFinalClass
    case openClass(alreadyFinal: Bool)
    case finalClassWithOpenMembers(hasNestedClasses: Bool)
    case nonFinalWithOpenMembers(hasNestedClasses: Bool)
    case nestedClasses
    case fixable

    var isValidFinalClass: Bool {
        if case .validFinalClass = self {
            return true
        }
        return false
    }
}

private enum OpenMemberPresence {
    case none
    case conditionalOnly
    case unconditional
}

private func finalClassValidationState(
    for classDeclaration: ClassDeclSyntax
) -> FinalClassValidationState {
    let isFinal = hasModifier(named: "final", in: classDeclaration.modifiers)
    if hasModifier(named: "open", in: classDeclaration.modifiers) {
        return .openClass(alreadyFinal: isFinal)
    }

    let openMembers = openMemberPresence(in: classDeclaration.memberBlock.members)
    if isFinal {
        switch openMembers {
        case .unconditional:
            return .finalClassWithOpenMembers(
                hasNestedClasses: hasNestedClass(in: classDeclaration.memberBlock)
            )
        case .none, .conditionalOnly:
            return .validFinalClass
        }
    }

    let hasNested = hasNestedClass(in: classDeclaration.memberBlock)
    switch openMembers {
    case .unconditional, .conditionalOnly:
        return .nonFinalWithOpenMembers(hasNestedClasses: hasNested)
    case .none:
        return hasNested ? .nestedClasses : .fixable
    }
}

private func openMemberPresence(in members: MemberBlockItemListSyntax) -> OpenMemberPresence {
    var sawConditionalOpenMember = false

    for member in members {
        if let ifConfig = member.decl.as(IfConfigDeclSyntax.self) {
            if hasAnyOpenMember(in: ifConfig) {
                sawConditionalOpenMember = true
            }
            continue
        }

        if member.decl.isProtocol(DeclGroupSyntax.self) {
            continue
        }

        if let modified = member.decl.asProtocol(WithModifiersSyntax.self),
           hasModifier(named: "open", in: modified.modifiers) {
            return .unconditional
        }
    }

    return sawConditionalOpenMember ? .conditionalOnly : .none
}

private func hasAnyOpenMember(in ifConfig: IfConfigDeclSyntax) -> Bool {
    for clause in ifConfig.clauses {
        guard case .decls(let conditionalMembers) = clause.elements else {
            continue
        }
        if openMemberPresence(in: conditionalMembers) != .none {
            return true
        }
    }

    return false
}

private func hasNestedClass(in memberBlock: MemberBlockSyntax) -> Bool {
    final class Finder: SyntaxVisitor {
        var found = false

        override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
            found = true
            return .skipChildren
        }
    }

    let finder = Finder(viewMode: .sourceAccurate)
    finder.walk(memberBlock)
    return finder.found
}
