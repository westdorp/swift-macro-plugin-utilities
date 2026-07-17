# swift-macro-plugin-utilities

`MacroPluginUtilities` provides focused syntactic queries, diagnostics, and
deterministic fix-its for Swift macro-plugin implementations. It is not a macro
framework, semantic type checker, or runtime library.

This repository is the canonical, living home of utilities originally frozen
from `westdorp/PrivatePlaybackStateMachineMacros` revision
`214443b8fb0d1ab228ab8b79d6c17d4f3497a7b6`.

Run the complete package gate with:

```sh
make test
```

Build with complete strict-concurrency checking using:

```sh
make build
```
