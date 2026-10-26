# Getting help

Where to go depends on what you need.

| I want to… | Go to |
| --- | --- |
| Report a bug in Umbra or a library | [Open an issue](https://github.com/alex-cova/Penumbra/issues/new) |
| Suggest a feature | [Open an issue](https://github.com/alex-cova/Penumbra/issues/new) and describe the problem first, then the idea |
| Ask how something works | Read the docs below, then [open an issue](https://github.com/alex-cova/Penumbra/issues/new) if they don't answer it |
| Report a security vulnerability | **Not a public issue.** Follow [SECURITY.md](SECURITY.md) |
| Report abusive behavior | Follow the [Code of Conduct](CODE_OF_CONDUCT.md) |
| Contribute a fix | [CONTRIBUTING.md](CONTRIBUTING.md) |

## Read first

- [README.md](README.md) for what Umbra and Penumbra are and how to build them
- [Umbra/README.md](Umbra/README.md) for day-to-day usage, shortcuts, signing and updates
- The `CLAUDE.md` file beside the code you are asking about (root, `Umbra/`, and most
  feature folders). They describe how each area works and why.
- [docs/PERFORMANCE_RULES.md](docs/PERFORMANCE_RULES.md) for performance questions
- [docs/ADDING_A_LANGUAGE.md](docs/ADDING_A_LANGUAGE.md) for language support

## Writing a useful bug report

Search the existing issues first. Then include:

- **Version.** The Umbra release (or the commit, if you built from source) and your macOS version
- **What you did, what you expected, and what happened.** Numbered steps, and a minimal
  project or file if you can share one
- **Project type.** For Java, Gradle or Maven questions: the build tool, your JDK version, and
  whether you opened a single module or the whole build
- **Agent problems.** The provider and model, the permission mode, and the prompt, with any
  keys, tokens and private code removed
- **Crashes.** The crash report from Console → Crash Reports, or the terminal output if you
  ran `swift run`
- **Performance.** The file size, the language, and whether Metal rendering was on. If you
  can, the numbers from `swift run -c release PerfHarness` (see CONTRIBUTING)

Remove credentials and personal data from everything you paste. A report that contains a
secret should be revoked and re-sent without it.

## What to expect

This is a small, maintainer-run project. Issues are read, but replies can take a while and
not every request will be accepted. A clear reproduction is the fastest way to a fix.
Support for a model provider, a language server or a build tool itself is outside this
project: report those upstream.
