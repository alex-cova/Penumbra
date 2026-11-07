const screenshotBase = "https://raw.githubusercontent.com/alex-cova/Penumbra/main/Screenshots";

const packageSnippet = `dependencies: [
    .package(url: "https://github.com/alex-cova/Penumbra.git", branch: "main")
]

.target(
    name: "YourAppTarget",
    dependencies: [
        .product(name: "Penumbra", package: "Penumbra"),
        .product(name: "EditorIntelligence", package: "Penumbra"),
        .product(name: "EditorIntelligenceLSP", package: "Penumbra"),
        .product(name: "PenumbraLanguages", package: "Penumbra")
    ]
)`;

const quickstartSnippet = `import AppKit
import Penumbra

let textView = TextView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
textView.theme = DefaultTheme()
textView.showLineNumbers = true
textView.isLineWrappingEnabled = true
textView.showMinimap = true
textView.isLineFoldingEnabled = true
textView.isMetalRenderingEnabled = true
textView.text = "// Welcome to Penumbra on macOS!"`;

const screenshots = [
  {
    src: `${screenshotBase}/home.png`,
    alt: "Umbra welcome screen with Open File, Open Folder, and keyboard shortcut hints",
    width: 2672,
    height: 1916,
    caption: "Welcome screen with quick-open shortcuts",
  },
  {
    src: `${screenshotBase}/markdown2.png`,
    alt: "Umbra editing Markdown with side-by-side live preview, syntax highlighting, and minimap",
    width: 2672,
    height: 1916,
    caption: "Markdown editing with live preview",
  },
  {
    src: `${screenshotBase}/swiftui.png`,
    alt: "Umbra editing SwiftUI with an iOS Simulator preview in a device frame beside the editor",
    width: 3236,
    height: 2240,
    caption: "SwiftUI editing with iOS Simulator preview",
  },
  {
    src: `${screenshotBase}/markdown.png`,
    alt: "Umbra Markdown preview rendering a flowchart diagram",
    width: 2672,
    height: 1916,
    caption: "Flowchart diagrams in Markdown preview",
  },
  {
    src: `${screenshotBase}/tools.png`,
    alt: "Umbra with project explorer, Java editor, integrated terminal, and Gradle tool window",
    width: 2684,
    height: 1904,
    caption: "Explorer, terminal, and Gradle tool window",
  },
  {
    src: `${screenshotBase}/git.png`,
    alt: "Umbra source control panel with staged changes, commit history, and inline diff",
    width: 2672,
    height: 1916,
    caption: "Git staging, history, and inline diff",
  },
  {
    src: `${screenshotBase}/ai.png`,
    alt: "Umbra AI coding agent panel reviewing file edits with accept and revert controls",
    width: 2672,
    height: 1916,
    caption: "AI coding agent with inline file edits",
  },
];

const stacks = [
  { name: "java", label: "Java" },
  { name: "gradle", label: "Gradle" },
  { name: "swift", label: "Swift" },
  { name: "git", label: "Git" },
  { name: "markdown", label: "Markdown" },
];

export default function Home() {
  return (
    <>
      <a className="skip-link" href="#main">
        Skip to content
      </a>

      <header className="site-header">
        <nav className="nav" aria-label="Primary">
          <a className="brand" href="#top">
            <img className="brand-icon" src="/umbra.png" alt="" width={32} height={32} />
            <span>Penumbra</span>
          </a>

          <button
            className="nav-toggle"
            type="button"
            aria-expanded="false"
            aria-controls="nav-menu"
            aria-label="Open menu"
          >
            <span className="nav-toggle-bar" />
            <span className="nav-toggle-bar" />
          </button>

          <div className="nav-links" id="nav-menu">
            <a href="#umbra">Umbra</a>
            <a href="#framework">Framework</a>
            <a href="#screenshots">Screenshots</a>
            <a href="#install">Install</a>
            <a href="https://github.com/alex-cova/Penumbra">GitHub</a>
          </div>
        </nav>
      </header>

      <main id="main">
        <div className="site-banner-wrapper">
          <div className="site-banner-container">
            <img
              src="/banner.png"
              alt="Umbra & Penumbra - Next-Generation Native macOS Code Editor"
              className="site-banner-img"
              width={1920}
              height={1080}
              fetchPriority="high"
            />
          </div>
        </div>

        <section className="hero" id="top">
          <div className="hero-copy">
            <h1>A fast macOS code editor and engine.</h1>
            <p>
              Umbra ships with Java and Gradle tooling, <code>.http</code> requests, Git, and Markdown
              preview. Penumbra is the Swift engine underneath.
            </p>
            <div className="cta-row">
              <a className="button button-primary" href="https://github.com/alex-cova/Penumbra/releases">
                Download Umbra
              </a>
              <a className="button button-secondary" href="#umbra">
                See what it does
              </a>
            </div>
          </div>

          <div className="hero-visual">
            <figure className="hero-shot">
              <img
                src={`${screenshotBase}/editor.png`}
                alt="Umbra editing a Java file with project explorer, minimap, and breadcrumbs"
                width={2684}
                height={1904}
                fetchPriority="high"
              />
            </figure>
          </div>
        </section>

        <section className="stack-strip" aria-label="Built with">
          <p className="stack-label">Languages and tools</p>
          <ul className="stack-logos">
            {stacks.map((stack) => (
              <li key={stack.name}>
                <img
                  src={`https://cdn.simpleicons.org/${stack.name}/9aa3b2`}
                  alt={stack.label}
                  width={28}
                  height={28}
                  loading="lazy"
                />
              </li>
            ))}
          </ul>
        </section>

        <section className="section umbra-section" id="umbra">
          <div className="section-head umbra-section-head reveal">
            <img
              className="umbra-app-icon"
              src="/umbra.png"
              alt="Umbra app icon"
              width={80}
              height={80}
              loading="lazy"
            />
            <div>
              <h2>Umbra, the editor app</h2>
              <p>
                A Sublime Text-style editor for macOS: open a folder, edit fast, and stay in one window for
                Java projects, API calls, docs, Git, and an AI coding agent. No Electron, no LSP server to
                configure for Java.
              </p>
            </div>
          </div>

          <div className="umbra-bento">
            <article className="umbra-card umbra-java reveal">
              <h3>Java and Gradle</h3>
              <p>
                Native <code>JavaIntelligence</code> indexes your JDK, project sources, and Gradle-resolved
                JARs. Sync a trusted Gradle build to load modules, dependencies, and source sets, then
                build from the editor and see compiler errors in the Problems panel.
              </p>
              <ul className="feature-list">
                <li>Smart completion with auto-import and parameter hints</li>
                <li>Hover with Javadoc, go to definition, implementation, and super method</li>
                <li>Find usages, rename, and type hierarchy</li>
                <li>
                  <code>javac</code> diagnostics, quick fixes, and optimize imports
                </li>
                <li>Gradle tool window: tasks, dependencies, source sets, reload and run</li>
                <li>Saved run configurations and classpath launch targets</li>
              </ul>
              <ul className="tag-list">
                <li>Completion</li>
                <li>Gradle sync</li>
                <li>Build project</li>
                <li>Run configs</li>
              </ul>
            </article>

            <article className="umbra-card umbra-http reveal">
              <h3>HTTP client</h3>
              <p>
                Edit IntelliJ-style <code>.http</code> request files with tree-sitter highlighting. Place
                the caret on a request and send it; status, timing, headers, and body appear in the
                response panel.
              </p>
              <ul className="tag-list">
                <li>.http files</li>
                <li>Send at caret</li>
                <li>Response panel</li>
              </ul>
            </article>

            <article className="umbra-card umbra-markdown reveal">
              <h3>Markdown preview</h3>
              <p>
                Side-by-side Markdown editing with live preview, fenced code highlighting, blockquotes,
                and Mermaid sequence, class, and flow diagrams.
              </p>
              <ul className="tag-list">
                <li>Live preview</li>
                <li>Mermaid</li>
                <li>Fenced code</li>
              </ul>
            </article>

            <article className="umbra-card umbra-git reveal">
              <h3>Git and source control</h3>
              <p>
                File status colors in the explorer, a source-control panel for stage and commit, inline
                diffs, history, branch switch, push, and fast-forward pull.
              </p>
              <ul className="tag-list">
                <li>Status colors</li>
                <li>Diff</li>
                <li>History</li>
              </ul>
            </article>

            <article className="umbra-card umbra-agent reveal">
              <h3>AI coding agent</h3>
              <p>
                Built on <code>AgentKit</code>: chat with local or cloud models, run tools against your
                project, and review file edits with accept or revert before they land on disk.
              </p>
              <ul className="tag-list">
                <li>Agent</li>
                <li>File edits</li>
                <li>Local models</li>
              </ul>
            </article>

            <article className="umbra-card umbra-workbench reveal">
              <h3>Editing and workbench</h3>
              <p>
                Tree-sitter highlighting for Swift, JS/TS, Python, JSON, YAML, HTML, and more. Multi-cursor
                editing, column selection, find and replace, optional Metal rendering, minimap, and folding.
              </p>
              <ul className="feature-list feature-list-compact">
                <li>Split editors, tab groups, and session restore</li>
                <li>Integrated terminal and Problems panel (⌘⇧M)</li>
                <li>Command palette, go to file, symbol, and line</li>
                <li>Structure view, breadcrumbs, and navigation history</li>
              </ul>
              <ul className="tag-list">
                <li>Multi-cursor</li>
                <li>Splits</li>
                <li>Terminal</li>
                <li>⌘P palette</li>
              </ul>
            </article>
          </div>
        </section>

        <section className="section bento-section" id="framework">
          <div className="section-head reveal">
            <h2>Penumbra, the framework</h2>
            <p>
              Forked from Runestone and ported to macOS. Use the Swift package in your own AppKit app:
              text engine, Editor Intelligence platform, LSP bridge, and workbench layout APIs.
            </p>
          </div>

          <div className="bento">
            <article className="bento-cell bento-engine reveal">
              <h3>Text engine</h3>
              <p>AppKit-native editing with optional Metal rendering and piece-tree storage for large files.</p>
              <ul className="tag-list">
                <li>Multi-cursor</li>
                <li>Tree-sitter</li>
                <li>Minimap</li>
                <li>Folding</li>
              </ul>
            </article>

            <article className="bento-cell bento-intel reveal">
              <h3>Editor Intelligence</h3>
              <p>Completion, hover, diagnostics, navigation, and rename through a provider-based platform.</p>
              <ul className="tag-list">
                <li>LSP</li>
                <li>Indexing</li>
                <li>Command palette</li>
              </ul>
            </article>

            <article className="bento-cell bento-workbench reveal">
              <h3>Workbench</h3>
              <p>Split panes, tab groups, session restore, and native AppKit bridge views for IDE chrome.</p>
            </article>

            <article className="bento-cell bento-languages reveal">
              <h3>JavaIntelligence</h3>
              <p>
                A separate Swift package wired into Umbra: JDK discovery, Gradle models, completion,
                diagnostics, navigation, refactoring, and semantic highlighting with no Penumbra dependency.
              </p>
            </article>
          </div>
        </section>

        <section className="section showcase-section" id="screenshots">
          <div className="section-head reveal">
            <h2>Umbra in action</h2>
            <p>
              Java and SwiftUI editing with live iOS Simulator preview, class diagrams, Markdown preview, Git
              source control, Gradle and terminal tooling, and an AI coding agent — all in one native macOS
              window.
            </p>
          </div>

          <figure className="showcase-primary reveal">
            <img
              src={`${screenshotBase}/diagram.png`}
              alt="Umbra Java class diagram blueprint showing types and relationships"
              width={2672}
              height={1916}
              loading="lazy"
            />
            <figcaption>Java class diagram blueprint</figcaption>
          </figure>

          <div className="screenshot-gallery">
            {screenshots.map((shot) => (
              <figure className="screenshot-card reveal" key={shot.src}>
                <img src={shot.src} alt={shot.alt} width={shot.width} height={shot.height} loading="lazy" />
                <figcaption>{shot.caption}</figcaption>
              </figure>
            ))}
          </div>
        </section>

        <section className="section install-section" id="install">
          <div className="install-layout">
            <div className="install-copy reveal">
              <h2>Get started</h2>
              <p>
                Download a release build of Umbra, or run it from source. To embed the editor engine in
                your own app, add Penumbra as a Swift package dependency.
              </p>

              <dl className="spec-list">
                <div>
                  <dt>Umbra app</dt>
                  <dd>
                    <a href="https://github.com/alex-cova/Penumbra/releases">GitHub Releases</a>
                    {" or "}
                    <code>swift run Umbra</code>
                  </dd>
                </div>
                <div>
                  <dt>Platform</dt>
                  <dd>macOS 26+, Swift 6.2, Xcode 26+</dd>
                </div>
                <div>
                  <dt>Tests</dt>
                  <dd>
                    1,050+ in <code>swift test</code>
                  </dd>
                </div>
              </dl>
            </div>

            <div className="code-panels reveal">
              <div className="code-panel">
                <div className="code-panel-head">
                  <span>Package.swift</span>
                  <button className="copy-btn" type="button" data-copy-target="install-code">
                    Copy
                  </button>
                </div>
                <pre className="code-block" id="install-code">
                  <code>{packageSnippet}</code>
                </pre>
              </div>

              <div className="code-panel">
                <div className="code-panel-head">
                  <span>AppKit</span>
                  <button className="copy-btn" type="button" data-copy-target="quickstart-code">
                    Copy
                  </button>
                </div>
                <pre className="code-block" id="quickstart-code">
                  <code>{quickstartSnippet}</code>
                </pre>
              </div>
            </div>
          </div>
        </section>
      </main>

      <footer className="footer">
        <p>Penumbra</p>
        <nav className="footer-links" aria-label="Footer">
          <a href="https://github.com/alex-cova/Penumbra">GitHub</a>
          <a href="https://github.com/alex-cova/Penumbra/blob/main/LICENSE">License</a>
          <a href="https://github.com/alex-cova/Penumbra/blob/main/THIRD_PARTY_NOTICES.md">
            Third-party notices
          </a>
        </nav>
      </footer>
    </>
  );
}
