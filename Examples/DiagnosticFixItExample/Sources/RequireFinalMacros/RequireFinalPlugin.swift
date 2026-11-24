import SwiftCompilerPlugin
import SwiftSyntaxMacros

@main
struct RequireFinalPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        RequireFinalMacro.self,
    ]
}
