import Foundation

enum GuardrailCommand {
    static func scan(
        config: URL, root: URL,
        read: (URL) throws -> Data = { try Data(contentsOf: $0) },
        list: (URL) throws -> [URL] = {
            try FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: [.fileResourceTypeKey])
        }
    ) -> GuardrailReport {
        do {
            let configData: Data
            do { configData = try read(config) }
            catch { throw inputError(error, operation: "read", target: "config \(config.path)") }
            let configuration: GuardrailConfiguration
            do { configuration = try GuardrailConfiguration.decode(configData) }
            catch { throw GuardrailInputError("\(config.path): \(error)") }
            let root = root.standardizedFileURL.resolvingSymlinksInPath()
            guard try fileType(at: root, named: "root \(root.path)") == .directory else {
                throw GuardrailInputError("Root must be a directory: \(root.path)")
            }
            let scopes = Set(configuration.rules.flatMap(\.paths))
            var files: Set<RelativePath> = []
            for scope in scopes.sorted(by: { $0.value < $1.value }) {
                var url = root
                for component in scope.value.components(separatedBy: "/") {
                    url.appendPathComponent(component)
                    if try fileType(at: url, named: "scope \(scope.value)") == .symbolicLink {
                        throw GuardrailInputError("Refusing symbolic link in source scope: \(url.path)")
                    }
                }
                let discovered = try discover(url: url, relative: scope, list: list)
                guard !discovered.isEmpty else {
                    throw GuardrailInputError("Scope contains no Swift files: \(scope.value)")
                }
                files.formUnion(discovered)
            }
            let sources = try files.sorted(by: { $0.value < $1.value }).map { file in
                let url = root.appendingPathComponent(file.value)
                let data: Data
                do { data = try read(url) }
                catch { throw inputError(error, operation: "read", target: file.value) }
                guard let text = String(data: data, encoding: .utf8) else {
                    throw GuardrailInputError("Source must be UTF-8: \(file.value)")
                }
                return GuardrailSource(file: file, text: text)
            }
            return try SourceGuardrails.scan(configuration: configuration, files: sources)
        } catch {
            return GuardrailReport(errors: [String(describing: error)])
        }
    }

    private static func inputError(_ error: any Error, operation: String, target: String) -> GuardrailInputError {
        if let error = error as? CocoaError, error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return GuardrailInputError("missing \(target)")
        }
        return GuardrailInputError("Cannot \(operation) \(target): \(error.localizedDescription)")
    }

    private static func fileType(at url: URL, named input: String) throws -> URLFileResourceType? {
        do { return try url.resourceValues(forKeys: [.fileResourceTypeKey]).fileResourceType }
        catch { throw inputError(error, operation: "inspect", target: input) }
    }

    private static func discover(
        url: URL, relative: RelativePath, list: (URL) throws -> [URL]
    ) throws -> Set<RelativePath> {
        let kind = try fileType(at: url, named: "scope \(relative.value)")
        switch kind {
        case .regular:
            return relative.value.hasSuffix(".swift") ? [relative] : []
        case .directory:
            let children: [URL]
            do { children = try list(url) }
            catch { throw inputError(error, operation: "list", target: relative.value) }
            var files: Set<RelativePath> = []
            for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let childPath = try RelativePath(relative.value + "/" + child.lastPathComponent)
                files.formUnion(try discover(url: child, relative: childPath, list: list))
            }
            return files
        case .symbolicLink:
            throw GuardrailInputError("Refusing symbolic link in source scope: \(relative.value)")
        default:
            throw GuardrailInputError("Expected a regular file or directory: \(relative.value)")
        }
    }
}
