import RequireFinal

@RequireFinal
final class Session {
    let name: String

    init(name: String) {
        self.name = name
    }
}

let session = Session(name: "example")
print("@RequireFinal accepted final class Session(\(session.name))")
