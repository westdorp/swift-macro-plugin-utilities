/// Requires the attached class declaration to be marked `final`.
@attached(peer)
public macro RequireFinal() = #externalMacro(
    module: "RequireFinalMacros",
    type: "RequireFinalMacro"
)
