import { UmbraWindow } from "./editor";

const releases = "https://github.com/alex-cova/Penumbra/releases";
const repo = "https://github.com/alex-cova/Penumbra";
const readme = "https://github.com/alex-cova/Penumbra/blob/main/Umbra/README.md";

function Arrow() {
  return (
    <svg className="m-arrow" viewBox="0 0 12 12" aria-hidden="true">
      <path className="m-arrow__stem" d="M1 6h8" />
      <path className="m-arrow__head" d="M4.5 2.5 8 6l-3.5 3.5" />
    </svg>
  );
}

const files = [
  ["Greeter.java", "src/main/java/app/Greeter.java", "Modified"],
  ["App.java", "src/main/java/app/App.java", "Open"],
  ["ContentView.swift", "Sources/ContentView.swift", "Open"],
  ["README.md", "README.md", "Open"],
];

const featureGroups = [
  {
    id: "editing",
    title: "Editing",
    items: [
      "Metal rendering, with a Core Graphics fallback",
      "Large files through a memory-mapped buffer",
      "Minimap, folding, focus mode and typewriter scrolling",
      "Multi-cursor and column selection",
      "Sublime-style keymap, with IntelliJ and default keymaps too",
      "Find and replace with regex captures and batch replace",
      "Smart indent, character pairs, surround-with and line moves",
      "Invisibles, page guide and line numbers",
      "Squiggles, and back and forward navigation history",
    ],
  },
  {
    id: "project",
    title: "Project",
    items: [
      "Explorer, split panes, tabs and a window per project",
      "Session restore",
      "Command palette, go to file, line and symbol",
      "Find in files",
      "Problems panel",
      "Local history of every save",
    ],
  },
  {
    id: "git",
    title: "Git",
    items: ["Stage and commit", "Diff tabs and change markers", "Commit history with a branch graph", "Unsynced commits and push"],
  },
  {
    id: "java",
    title: "Java and Gradle",
    items: [
      "Gradle sync and tasks, with Maven, SwiftPM and npm projects recognised",
      "Completion, inspections and refactoring without a JVM IDE",
      "Run configurations and a test gutter",
      "JDI debugger",
      "Coverage with JaCoCo",
      "Profiling with Java Flight Recorder and a flame graph",
      "Class and dependency diagrams",
    ],
  },
  {
    id: "intelligence",
    title: "Intelligence",
    items: [
      "Symbol-index completion",
      "Hover, go to definition and find usages",
      "Rename with preview",
      "Inlay hints and code vision",
      "Native Java, TypeScript and Swift intelligence",
      "Language servers over LSP",
      "SwiftUI previews beside the code",
    ],
  },
  {
    id: "languages",
    title: "Languages",
    items: [
      "Tree-sitter highlighting that updates as you type",
      "Swift, Java, Kotlin, Go and Rust",
      "JavaScript, TypeScript and Python",
      "JSON, YAML, HTML, Markdown, SQL and HTTP",
      "Injected languages, such as CSS and JavaScript inside HTML",
    ],
  },
  {
    id: "tools",
    title: "Built-in tools",
    items: [
      "Integrated terminal",
      "Run and debug windows, with JDI for Java and DAP for Swift and JavaScript",
      "Hex editor",
      "CSV table preview",
      "Markdown and JSON diagram preview",
      "HTTP client with variables and cookies",
      "Text tools: encode and decode, JSON format, JWT decode and hashes",
    ],
  },
  {
    id: "agent",
    title: "Coding agent",
    items: [
      "Chat docked beside the editor or full width",
      "Reads, searches and edits your real workspace, including unsaved buffers",
      "Edits land in open tabs, so undo works, and Revert run restores the checkpoint",
      "Shell, Gradle and test tasks, with your approval",
      "Plan, ask and auto permission modes",
      "File mentions, slash commands and project skills",
      "Instructions from AGENTS.md or CLAUDE.md",
      "Meta Muse, OpenAI-compatible APIs, Ollama, and on-device models through MLX or Apple Intelligence",
      "Keys stay in the Keychain",
    ],
  },
];

export default function Home() {
  return (
    <>
      <header className="nav nav--centre">
        <div className="wrap nav__bar">
          <a className="skip-link" href="#top">
            Skip to content
          </a>
          <a className="nav__logo" href="#top">
            <img src="/umbra.png" alt="" width={28} height={28} />
            Umbra
          </a>
          <nav className="nav__links" aria-label="Primary">
            <a className="nav__link" href="#editor">
              Editor
            </a>
            <a className="nav__link" href="#features">
              Features
            </a>
            <a className="nav__link" href="#questions">
              Questions
            </a>
            <a className="nav__link" href={repo}>
              GitHub
            </a>
          </nav>
          <div className="nav__actions">
            <a className="btn btn--primary" href={releases}>
              Download Umbra
              <Arrow />
            </a>
          </div>
          <button className="nav__toggle" type="button" aria-expanded="false" aria-label="Menu">
            <svg width="18" height="18" viewBox="0 0 18 18" aria-hidden="true">
              <path d="M2 5h14M2 13h14" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" />
            </svg>
          </button>
        </div>
      </header>

      <main id="top">
        <section className="hero hero--collage" data-enter aria-labelledby="hero-h">
          <div className="wrap">
            <div className="hero-text grid hero__grid">
              <div className="hero__text span-5">
                <h1 id="hero-h">Code editor for macOS developers</h1>
                <p className="hero__lead">
                  Umbra is an AppKit editor on Penumbra. Open a folder, edit with a Sublime keymap, and keep Java
                  intelligence and a coding agent in one window.
                </p>
                <div className="btn-row">
                  <a className="btn btn--primary" href={releases}>
                    Download Umbra
                    <Arrow />
                  </a>
                  <a className="btn btn--secondary" href={repo}>
                    See the repository
                  </a>
                </div>
                <p className="hero__proof">Requires macOS 26.</p>
              </div>
            </div>
            <div className="hero__window" id="editor">
              <UmbraWindow />
              <div className="hero__note">
                <p>
                  This is a working copy of the window. Type in a buffer, preview README.md, open ledger.bin and app.jfr,
                  run a command in the terminal, ask the agent, or stage and commit a change.
                </p>
                <a className="link" href={`${repo}#highlights`}>
                  Read the editing notes
                </a>
              </div>
            </div>
          </div>
        </section>

        <section className="section bg-grain" id="features" aria-labelledby="features-h">
          <div className="wrap">
            <div className="group">
              <div className="section-head">
                <h2 id="features-h">
                  Features in the Umbra window. <span className="muted">Each card is a control the editor already ships.</span>
                </h2>
              </div>
              <div className="grid">
                <article className="card card--row card--open span-6">
                  <h3>Open an Umbra project file</h3>
                  <p>Choose a file in the explorer. Umbra opens it in the active tab and keeps the caret.</p>
                  <div className="panel panel--device" role="img" aria-label="Project files in the Umbra explorer">
                    <div className="stage stage--fade-br">
                      <div className="at-corner" style={{ ["--ax" as string]: "24px", ["--ay" as string]: "28px" }} data-ui-loop>
                        <div className="ui ui-panel ui-win" data-ui="window" data-ui-opts='{"compact":true}' data-open="Open" data-work="Modified" data-done="Saved">
                          <div className="ui-win__bar">
                            <span className="ui-dots" aria-hidden="true">
                              <i />
                              <i />
                              <i />
                            </span>
                            <span className="ui-win__crumb">
                              ledger <i>/</i> <b>Explorer</b>
                            </span>
                          </div>
                          <div className="ui-win__body">
                            <nav className="ui-win__side" aria-hidden="true">
                              <span className="ui-win__nav is-on">Explorer</span>
                              <span className="ui-win__nav">Structure</span>
                              <span className="ui-win__nav">Changes</span>
                              <span className="ui-win__nav">History</span>
                            </nav>
                            <div className="ui-win__main">
                              <div className="ui-win__cols" aria-hidden="true">
                                <span>File</span>
                                <span>Path</span>
                                <span>State</span>
                              </div>
                              <ul className="ui-win__rows">
                                {files.map(([name, path, state], index) => (
                                  <li className={index >= 2 ? "ui-win__row phone-cut" : "ui-win__row"} data-row key={name}>
                                    <span className="ui-win__who">{name}</span>
                                    <span className="ui-win__sub">{path}</span>
                                    <span className={state === "Modified" ? "ui-win__st is-you" : "ui-win__st"} data-st>
                                      {state}
                                    </span>
                                  </li>
                                ))}
                              </ul>
                            </div>
                          </div>
                        </div>
                      </div>
                    </div>
                  </div>
                </article>
                <article className="card card--row card--open span-6">
                  <h3>Complete a Java name</h3>
                  <p>Press ⌃Space in the buffer. The symbol index offers greet from Greeter.</p>
                  <div className="panel" role="img" aria-label="Completion list for greet">
                    <div className="stage stage--fade-b">
                      <div className="at-rise fit" style={{ ["--fit-max" as string]: "400px", ["--ax" as string]: "32px", ["--ax-sm" as string]: "6px", ["--ay" as string]: "56px" }}>
                        <div className="ui ui-panel ui-search" data-ui="search">
                          <div className="ui-search__field">
                            <span className="ui-search__q">
                              <span data-search-q>greet</span>
                              <i className="ui-search__caret" />
                            </span>
                            <kbd className="ui-search__kbd">⌃Space</kbd>
                          </div>
                          <div className="ui-search__group">Symbols</div>
                          <ul className="ui-search__list" data-search-list>
                            <li className="ui-search__row is-sel">
                              <span className="ui-search__t">
                                <b>greet</b>
                              </span>
                              <span className="ui-search__m">Greeter</span>
                            </li>
                            <li className="ui-search__row">
                              <span className="ui-search__t">
                                <b>greet</b>Loud
                              </span>
                              <span className="ui-search__m">Greeter</span>
                            </li>
                            <li className="ui-search__row">
                              <span className="ui-search__t">Greeter.java</span>
                              <span className="ui-search__m">File</span>
                            </li>
                          </ul>
                        </div>
                      </div>
                    </div>
                  </div>
                </article>
              </div>
            </div>
            <div className="group">
              <div className="grid">
                <article className="card card--row card--open span-6">
                  <h3>Stage a changed Umbra file</h3>
                  <p>Changes lists Greeter.java as modified. Stage it there before the commit.</p>
                  <div className="panel" role="img" aria-label="Checklist for staging Greeter.java">
                    <div className="stage stage--fade-b">
                      <div className="at-rise fit" style={{ ["--ax" as string]: "32px", ["--ax-sm" as string]: "6px", ["--ay" as string]: "calc(100% - 180px)" }}>
                        <div className="ui ui-panel ui-checks" data-ui="checklist">
                          <div className="ui-checks__head">
                            <div className="ui-title">Changes</div>
                            <span className="ui-spacer" />
                            <div className="ui-meta" data-checks-count>
                              1 of 3
                            </div>
                          </div>
                          <div className="ui-checks__bar">
                            <i data-checks-bar style={{ ["--k" as string]: 0.33 }} />
                          </div>
                          <ul className="ui-checks__list">
                            <li className="ui-check is-done">
                              <span className="ui-check__box">
                                <svg viewBox="0 0 16 16">
                                  <path d="m4.5 8.2 2.3 2.3 4.7-5" />
                                </svg>
                              </span>
                              <span className="ui-check__label">Stage Greeter.java</span>
                            </li>
                            <li className="ui-check">
                              <span className="ui-check__box">
                                <svg viewBox="0 0 16 16">
                                  <path d="m4.5 8.2 2.3 2.3 4.7-5" />
                                </svg>
                              </span>
                              <span className="ui-check__label">Review the diff</span>
                            </li>
                            <li className="ui-check phone-cut">
                              <span className="ui-check__box">
                                <svg viewBox="0 0 16 16">
                                  <path d="m4.5 8.2 2.3 2.3 4.7-5" />
                                </svg>
                              </span>
                              <span className="ui-check__label">Commit from Changes</span>
                            </li>
                          </ul>
                        </div>
                      </div>
                    </div>
                  </div>
                </article>
                <article className="card card--row card--open span-6">
                  <h3>Revert an agent run</h3>
                  <p>The agent writes into the open tab. Revert run restores the checkpoint.</p>
                  <div className="panel" role="img" aria-label="Notices for an agent edit and its checkpoint">
                    <div className="stage stage--fade-b">
                      <div className="at-rise fit" style={{ ["--ax" as string]: "32px", ["--ax-sm" as string]: "6px", ["--ay" as string]: "calc(100% - 180px)" }}>
                        <div className="ui ui-notify" data-ui="notify">
                          <ul className="ui-notify__list" data-notify-list>
                            <li className="ui-note">
                              <span className="ui-note__text">
                                <span className="ui-note__title">
                                  Edit applied in the tab
                                  <time>now</time>
                                </span>
                                <span className="ui-note__body">Greeter.greet changed in the buffer</span>
                              </span>
                              <span className="ui-btn ui-btn--sm ui-note__btn">Revert run</span>
                            </li>
                            <li className="ui-note">
                              <span className="ui-note__text">
                                <span className="ui-note__title">
                                  Checkpoint kept
                                  <time>now</time>
                                </span>
                                <span className="ui-note__body">Undo still applies to the tab</span>
                              </span>
                            </li>
                          </ul>
                        </div>
                      </div>
                    </div>
                  </div>
                </article>
              </div>
              <div className="lang-strip" aria-label="Languages with tree-sitter highlighting in Umbra">
                <ul className="lang-strip__list">
                  {[
                    "Swift",
                    "Java",
                    "Kotlin",
                    "Go",
                    "Rust",
                    "JavaScript",
                    "TypeScript",
                    "Python",
                    "JSON",
                    "YAML",
                    "HTML",
                    "Markdown",
                    "SQL",
                    "HTTP",
                  ].map((name) => (
                    <li key={name}>{name}</li>
                  ))}
                </ul>
              </div>
            </div>
          </div>
        </section>

        <section className="section" id="jobs" aria-labelledby="jobs-h">
          <div className="wrap">
            <div className="grid">
              <div className="span-5">
                <div className="section-head">
                  <h2 id="jobs-h">Three jobs in one frame</h2>
                  <p>The frame stays put while you switch jobs, so the diff, the buffer and the chat occupy the same rectangle.</p>
                </div>
                <div className="tabs" role="tablist" aria-label="Jobs">
                  <button className="tab" type="button" role="tab" id="tab-edit" aria-selected="true" aria-controls="panel-edit screen-edit">
                    Edit a buffer
                  </button>
                  <button className="tab" type="button" role="tab" id="tab-diff" aria-selected="false" aria-controls="panel-diff screen-diff">
                    Review a diff
                  </button>
                  <button className="tab" type="button" role="tab" id="tab-agent" aria-selected="false" aria-controls="panel-agent screen-agent">
                    Ask the agent
                  </button>
                </div>
                <div id="panel-edit" role="tabpanel" aria-labelledby="tab-edit">
                  <p>The open buffer is Greeter.java in Armada Dark. Menlo is the face, at 13 points.</p>
                  <a className="link" href={`${repo}#highlights`}>
                    Read the editing notes
                  </a>
                </div>
                <div id="panel-diff" role="tabpanel" aria-labelledby="tab-diff" hidden>
                  <p>The diff is the agent edit in Greeter.java. Revert run restores the checkpoint.</p>
                  <a className="link" href={`${repo}#coding-agent`}>
                    Read the agent notes
                  </a>
                </div>
                <div id="panel-agent" role="tabpanel" aria-labelledby="tab-agent" hidden>
                  <p>The chat is docked beside the buffer. An edit lands in the open tab, and undo still works.</p>
                  <a className="link" href={`${repo}#coding-agent`}>
                    Read the model list
                  </a>
                </div>
              </div>
              <div className="frame frame--split span-6 start-7">
                <div className="stage stage--fade-br">
                  <div id="screen-edit" data-ui-loop>
                    <div className="ui ui-panel ui-code at-rise to-edge" data-ui="code">
                      <div className="ui-code__tabs">
                        <span className="ui-code__tab is-on">
                          <i className="ui-code__lang">Java</i>Greeter.java
                        </span>
                        <span className="ui-spacer" />
                      </div>
                      <pre className="ui-code__pre">
                        <code>
                          <span className="ui-code__ln" data-n="3">
                            <span className="k">public</span> <span className="k">final</span> <span className="k">class</span> Greeter {"{"}
                          </span>
                          <span className="ui-code__ln" data-n="4">
                            {"    "}
                            <span className="k">private</span> <span className="k">final</span> String name;
                          </span>
                          <span className="ui-code__ln" data-n="5">
                            {"    "}
                            <span className="k">public</span> Greeter(String name) {"{"}
                          </span>
                          <span className="ui-code__ln" data-n="6">
                            {"        this.name = name;"}
                          </span>
                          <span className="ui-code__ln" data-n="7">
                            {"    }"}
                          </span>
                          <span className="ui-code__ln" data-n="8">
                            {"    "}
                            <span className="k">public</span> String <span className="f">greet</span>() {"{"}
                          </span>
                          <span className="ui-code__ln" data-n="9">
                            <span className="c">{"        // Tree-sitter colours this comment."}</span>
                          </span>
                          <span className="ui-code__ln is-mark" data-n="10">
                            {"        "}
                            <span className="k">return</span> <span className="s">{'"Hello, "'}</span> + name;
                          </span>
                          <span className="ui-code__ln" data-n="11">
                            {"    }"}
                          </span>
                        </code>
                      </pre>
                      <div className="ui-code__hint" data-code-hint>
                        <span className="ui-dot" />
                        <span data-code-text>Caret on the return in greet.</span>
                      </div>
                      <div className="ui-code__status" aria-hidden="true">
                        <span>Ln 10 · Col 16</span>
                        <span>JDK 26 · Java · UTF-8 · LF</span>
                      </div>
                    </div>
                  </div>
                  <div id="screen-diff" hidden>
                    <div className="ui ui-panel ui-diff at-rise to-edge" data-ui="diff-review">
                      <div className="ui-diff__head">
                        <span className="ui-diff__path">
                          <span className="ui-diff__dir">src/main/java/app/</span>
                          <b>Greeter.java</b>
                        </span>
                        <span className="ui-spacer" />
                        <span className="ui-diff__stat">
                          <b className="is-add">+1</b>
                          <b className="is-del">−1</b>
                        </span>
                      </div>
                      <div className="ui-diff__hunk">
                        <span>@@ greet @@</span>
                      </div>
                      <div className="ui-diff__lines">
                        <div className="ui-diff__ln is-del">
                          <i>12</i>
                          <i />
                          <span className="ui-diff__code">
                            <span className="k">return</span> name;
                          </span>
                        </div>
                        <div className="ui-diff__ln is-add">
                          <i />
                          <i>12</i>
                          <span className="ui-diff__code">
                            <span className="k">return</span> <span className="s">{'"Hello, "'}</span> + name;
                          </span>
                        </div>
                        <div className="ui-diff__thread">
                          <div className="ui-diff__by">
                            <span className="ui-diff__name">Agent</span>
                            <span className="ui-spacer" />
                            <button className="ui-btn ui-btn--sm" type="button" tabIndex={-1}>
                              Revert run
                            </button>
                          </div>
                          <div className="ui-diff__msg">The edit is in the open tab.</div>
                        </div>
                      </div>
                    </div>
                  </div>
                  <div id="screen-agent" hidden>
                    <div className="ui ui-panel ui-chat at-rise to-edge" data-ui="chat">
                      <div className="ui-head">
                        <div className="ui-title">Agent</div>
                      </div>
                      <div className="ui-chat__body">
                        <div className="ui-msg ui-msg--me" data-chat-q>
                          <span className="ui-msg__text">Rename greet to hello in Greeter.java.</span>
                        </div>
                        <div className="ui-msg ui-msg--bot" data-chat-a>
                          <span className="ui-msg__col">
                            <span className="ui-chat__answer">
                              I edited Greeter.java in the open tab. Revert run puts the checkpoint back.
                            </span>
                          </span>
                        </div>
                      </div>
                    </div>
                  </div>
                </div>
              </div>
            </div>
          </div>
        </section>

        <section className="section bg-dots" id="all-features" aria-labelledby="all-features-h">
          <div className="wrap">
            <div className="section-head">
              <h2 id="all-features-h">Everything in Umbra</h2>
              <p>The whole feature list, from the text engine to the coding agent.</p>
            </div>
            <p className="section-link span-12">
              <a className="link" href={`${repo}#highlights`}>
                Read the highlights
              </a>
            </p>
            <div className="feature-grid">
              {featureGroups.map((group) => (
                <section className="feature-group" key={group.title} aria-labelledby={`fg-${group.id}`}>
                  <h3 id={`fg-${group.id}`}>{group.title}</h3>
                  <ul>
                    {group.items.map((item) => (
                      <li key={item}>{item}</li>
                    ))}
                  </ul>
                </section>
              ))}
            </div>
          </div>
        </section>

        <section className="section" id="questions" aria-labelledby="questions-h">
          <div className="wrap">
            <div className="group">
              <div className="grid">
                <div className="section-head span-5">
                  <img className="section-icon" src="/umbra.png" alt="Umbra app icon" width={32} height={32} />
                  <h2 id="questions-h">Questions</h2>
                  <p>Install, the license, and the machines it runs on.</p>
                  <a className="link" href={readme}>
                    Read the install notes
                  </a>
                </div>
                <div className="faq span-6 start-7">
                  <div className="faq__item">
                    <h3>Which Umbra file do I unzip?</h3>
                    <p>Unzip the macOS zip from GitHub Releases, move Umbra.app, and open it.</p>
                  </div>
                  <div className="faq__item">
                    <h3>Is Umbra on Homebrew?</h3>
                    <p>No formula or tap is published, so the zip is the install.</p>
                  </div>
                  <div className="faq__item">
                    <h3>How do I build Umbra?</h3>
                    <p>Run ./run.sh, or Scripts/build-app.sh for the release bundle. Both need macOS 26 and Xcode 26.</p>
                  </div>
                  <div className="faq__item">
                    <h3>What license covers Umbra?</h3>
                    <p>Apache License 2.0, with no CLA.</p>
                  </div>
                  <div className="faq__item">
                  <h3>How do Umbra updates arrive?</h3>
                  <p>Sparkle checks the stable feed at alex-cova.github.io/Penumbra/appcast.xml.</p>
                </div>
                <div className="faq__item">
                  <h3>Does Umbra run on Windows?</h3>
                  <p>No. Umbra is a macOS app.</p>
                </div>
                <div className="faq__item">
                  <h3>Where is the Umbra source?</h3>
                  <p>
                    The repository is{" "}
                    <a className="link" href={repo}>
                      github.com/alex-cova/Penumbra
                    </a>
                    .
                  </p>
                </div>
                </div>
              </div>
            </div>
          </div>
        </section>
      </main>

      <footer className="footer closing footer--dark ground-inverse" id="contact" aria-labelledby="close-h">
        <div className="wrap">
          <div className="closing__cta close--word">
            <div className="section-head--split">
              <div>
                <h2 id="close-h">Install Umbra on your Mac</h2>
                <p className="t-lead">The current asset is Umbra-1.6.21-macOS.zip.</p>
              </div>
              <a className="btn btn--primary" href={releases}>
                Download Umbra
                <Arrow />
              </a>
            </div>
            <p className="close__word" aria-hidden="true">
              Umbra
            </p>
          </div>
          <div className="closing__links">
            <div className="grid">
              <div className="span-4 stack-4">
                <a className="nav__logo" href="#top">
                  <img src="/umbra.png" alt="" width={28} height={28} />
                  Umbra
                </a>
                <p className="footer__lede">Native code editor for macOS.</p>
              </div>
              <div className="span-2 footer__col">
                <h3>Editor</h3>
                <ul>
                  <li>
                    <a href="#editor">The window</a>
                  </li>
                  <li>
                    <a href="#jobs">Three jobs</a>
                  </li>
                </ul>
              </div>
              <div className="span-2 footer__col">
                <h3>Features</h3>
                <ul>
                  <li>
                    <a href="#features">Four parts</a>
                  </li>
                  <li>
                    <a href="#all-features">All features</a>
                  </li>
                </ul>
              </div>
              <div className="span-2 footer__col">
                <h3>Questions</h3>
                <ul>
                  <li>
                    <a href="#questions">Install</a>
                  </li>
                  <li>
                    <a href={readme}>Install notes</a>
                  </li>
                </ul>
              </div>
              <div className="span-2 footer__col">
                <h3>GitHub</h3>
                <ul>
                  <li>
                    <a href={repo}>Repository</a>
                  </li>
                  <li>
                    <a href={`${repo}/blob/main/LICENSE`}>License</a>
                  </li>
                  <li>
                    <a href={`${repo}/blob/main/CONTRIBUTING.md`}>Contributing</a>
                  </li>
                  <li>
                    <a href={`${repo}/blob/main/SECURITY.md`}>Security</a>
                  </li>
                </ul>
              </div>
            </div>
            <div className="footer__legal">
              <span>© 2026 Umbra</span>
              <div className="socials" />
            </div>
          </div>
        </div>
      </footer>

      <nav className="actionbar" aria-label="Quick actions">
        <a className="btn btn--primary" href={releases}>
          Download Umbra
          <Arrow />
        </a>
      </nav>
    </>
  );
}
