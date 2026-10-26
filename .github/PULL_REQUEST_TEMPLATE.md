## What and why

<!-- What changes, and what problem it solves. Link the issue: Fixes #123 -->

## Area

<!-- Tick everything this touches. -->

- [ ] Libraries (`Sources/`, root `Package.swift`)
- [ ] Umbra app (`Umbra/Sources/Umbra`)
- [ ] Agent (`Packages/AgentKit*`, `Umbra/Sources/Umbra/Agent`)
- [ ] Language support (grammar, queries, language service)
- [ ] Docs, scripts, CI or project files only

## How I tested it

<!-- The commands you ran and the result. Say what you could not test and why. -->

```text
swift test ...
swift test --package-path Umbra ...
```

## Checklist

- [ ] I reviewed my full diff: no credentials, no stray generated files, no unrelated formatting
- [ ] Tests added or updated for new behavior or the bug fixed
- [ ] The libraries still build on their own (`swift build` at the repository root), and nothing in them depends on `Umbra`, `AgentKit*`, Sparkle, SwiftTerm, DiagramKit or `DatabaseKit`
- [ ] `Penumbra` stays App Store–safe: public APIs only, no `Process`, no hidden network calls
- [ ] `Package.resolved` is unchanged, or I explain the dependency change below
- [ ] Docs and the nearby `CLAUDE.md` are updated if behavior or rules changed

## Screenshots or numbers

<!-- UI change: before and after. Typing, layout, scrolling or highlighting change: PerfHarness output on the parent commit and on this one (release build). Delete this section if neither applies. -->

## Risks and anything to look at closely

<!-- Agent permissions, project trust, file access, data leaving the Mac, migrations of saved state, behavior changes. Say "none" if none. -->
