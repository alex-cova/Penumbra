# UX specification

Umbra keeps its own design language: the `IDEAppearance` tokens, `IDEIconButton`/`IDEIconMenu`, `IDEChromeTabItem`, `SplitPanes` for every split, and the existing sidebar and bottom-panel contribution points. DataGrip, TablePlus, DBeaver, Postico and Compass are used as behavioural benchmarks (what a user expects a key or a menu to do), not as visual templates.

## Workspace

```
┌ Database sidebar ┐ ┌ Editor: query console / object DDL / table ─────────┐ ┌ Inspector (optional) ┐
│ explorer tree    │ │ console header: source · database · schema ·        │ │ value / record /      │
│                  │ │   tx mode+state · read-only · environment colour    │ │ chart / AI context    │
│                  │ ├─────────────────────────────────────────────────────┤ │                       │
│                  │ │ SQL text                                            │ │                       │
│                  │ ├─────────────────────────────────────────────────────┤ │                       │
└──────────────────┘ │ Bottom panel: Query Results (a sub-tab per run),     │ └───────────────────────┘
                     │ notices, plan                                        │
                     └──────────────────────────────────────────────────────┘
```

- No new permanent panels. The inspector is contextual: it opens for a selected value, a record, a chart or the AI context, and closes with Esc.
- The sidebar stays the existing "Database" tab; the results stay the existing bottom-panel tab, now with sub-tabs.

## Always visible in a console

Connection name, database, schema (pickers), transaction mode (Auto / Manual) and state, a read-only badge, and an environment colour for production sources. The state strings are fixed: **Local edits**, **Submitted (uncommitted)**, **In transaction**, **Committed**, **Failed**. A user must never wonder which one applies.

## Keyboard (proposed; each is checked for conflicts against every keymap preset in a test)

| Action | Default |
|---|---|
| Execute statement at caret, or the selection | ⌘↩ |
| Execute all statements | ⇧⌘↩ |
| Cancel running statement | ⌘. |
| Explain | ⌥⌘E |
| Commit / Rollback (manual mode) | ⌥⌘↩ / ⌥⌘⌫ |
| Open value inspector | ⌘I on a cell |
| Go to related row (foreign key) | ⌘↓ on a cell |
| Back / forward through related rows | ⌘[ / ⌘] while the grid is focused |
| Palette | every command also appears under "Database:" |

Everything reachable by mouse is reachable by keyboard: connect, run, move between result cells, edit a cell (Return), set NULL, revert, submit, commit, export.

## Result grid rules

- NULL, empty string, zero, a missing Mongo field, binary, truncated and not-yet-loaded values each have a different rendering (italic `NULL`, a visible empty marker, `0`, a dimmed `missing`, `‹BLOB 2.1 MB›`, `…` with the size, a placeholder bar). A legend is one click away.
- A cell never renders more than a bounded preview; the inspector loads the rest on demand.
- A partial, sampled or cached result always says so in the footer ("Loaded 2,000 of more rows", "Sample of 5,000", "From cache, run again to refresh").
- Pending, submitted, failed and committed edits are distinguished by more than colour (marker shapes), for accessibility.

## Editing

Editing a cell stages it. Nothing is sent until **Submit**. Submit opens a preview (statements, bound parameters, target, expected row counts, transaction effect). A result that cannot be edited safely says why in the toolbar ("Not editable: result joins two tables"), never silently.

## Errors and empty states

- Errors show the server's message, the statement position (underlined in the editor), and one useful action (Retry, Edit connection, Reconnect, Open log).
- A SQLite file that is locked offers Retry. A TLS failure names the mode and the certificate problem.
- Empty states say what to do: no sources → "Add a data source" and "Open a SQLite file"; no rows → shows the statement and duration.

## Connection editor

A single large sheet with sections General, Authentication, Network, TLS, Advanced, Session. SQLite shows only the file section (path, read-only, create, busy timeout). Test Connection reports which step failed (DNS, TCP, TLS, authentication, database).

## AI surfaces

- Actions on selected SQL and on errors: Explain, Optimize, Fix, Convert dialect, Explain plan.
- A **context inspector** sheet lists exactly what a request will include (schema names, columns, the statement, the error, result rows) and lets the user remove items. Result rows are never included unless the user selected them.
- Generated SQL lands in the editor as text. It is never executed automatically.

## Avoid

Cards inside cards, nested scroll views, modal dialogs for routine work, disabled controls without an explanation, decorative animation, web-dashboard styling.

## Accessibility

Every control has a label; the grid exposes rows and cells to VoiceOver with column name and value; focus survives refreshes; light and dark both verified.
