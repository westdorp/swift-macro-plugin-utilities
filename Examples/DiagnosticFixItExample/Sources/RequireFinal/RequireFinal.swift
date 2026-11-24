/// Requires the attached class declaration to be marked `final`.
///
/// Syntactic macro expansion inspects only the attached class declaration,
/// so verify that no sibling or cross-file declaration subclasses the type
/// before applying the `'final'` fix-it.
@attached(peer)
public macro RequireFinal() = #externalMacro(
    module: "RequireFinalMacros",
    type: "RequireFinalMacro"
)
