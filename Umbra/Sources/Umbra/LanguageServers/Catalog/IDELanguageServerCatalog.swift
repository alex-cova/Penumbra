import EditorIntelligence
import Foundation

/// The language servers Umbra can drive beyond its native engines. Java stays native, and Swift,
/// TypeScript and Python keep their dedicated definitions; everything below is data.
///
/// Server choices and commands come from each project's own documentation (checked 2026-11-16 only
/// where noted in `docs/LANGUAGE_SERVERS.md`); a server Umbra cannot find is shown as "not installed" with
/// the install commands, never installed for the user.
enum IDELanguageServerCatalog {
    static let all: [IDELanguageServerSpec] = [
        IDELanguageServerSpec(
            id: "intelephense", displayName: "PHP", languageIDs: ["php"],
            executables: ["intelephense"], arguments: ["--stdio"],
            versionArguments: nil,
            projectMarkers: ["composer.json"], sourceExtensions: ["php"],
            projectLocalPaths: ["node_modules/.bin/intelephense"],
            prerequisite: "Node.js",
            installInstructions: ["npm install -g intelephense"],
            installURL: "https://intelephense.com",
            licence: "Proprietary, free tier. Premium features (rename, references across files, …) need a licence key the user buys.",
            notes: "Set the licence key through the server's own `intelephense.licenceKey` setting.",
            diagnosticSource: DiagnosticSourceID(rawValue: "php-lsp")
        ),
        IDELanguageServerSpec(
            id: "rust-analyzer", displayName: "Rust", languageIDs: ["rust"],
            executables: ["rust-analyzer"],
            projectMarkers: ["Cargo.toml"], sourceExtensions: ["rs"],
            extraSearchDirectories: ["~/.cargo/bin", "~/.rustup/toolchains/stable-aarch64-apple-darwin/bin"],
            prerequisite: "Rust toolchain (rustup)",
            installInstructions: ["rustup component add rust-analyzer", "brew install rust-analyzer"],
            installURL: "https://rust-analyzer.github.io/book/installation.html",
            licence: "MIT OR Apache-2.0",
            notes: "Indexes the Cargo workspace on start; first diagnostics wait for `cargo check`.",
            diagnosticSource: DiagnosticSourceID(rawValue: "rust-analyzer")
        ),
        IDELanguageServerSpec(
            id: "csharp-ls", displayName: "C#", languageIDs: ["csharp"],
            lspLanguageIDs: ["csharp": "csharp"],
            executables: ["csharp-ls"],
            projectMarkers: ["*.sln", "*.slnx", "*.csproj"], sourceExtensions: ["cs"],
            extraSearchDirectories: ["~/.dotnet/tools"],
            prerequisite: ".NET SDK",
            installInstructions: ["dotnet tool install --global csharp-ls"],
            installURL: "https://github.com/razzmatazz/csharp-language-server",
            licence: "MIT",
            notes: "Community Roslyn-based server, a single stdio binary. Microsoft's Roslyn language server and OmniSharp need extra launch plumbing and are not used.",
            diagnosticSource: DiagnosticSourceID(rawValue: "csharp-lsp")
        ),
        IDELanguageServerSpec(
            id: "kotlin-lsp", displayName: "Kotlin", languageIDs: ["kotlin"],
            executables: ["kotlin-lsp", "kotlin-lsp.sh"], arguments: ["--stdio"],
            versionArguments: nil,
            projectMarkers: ["build.gradle.kts", "settings.gradle.kts", "build.gradle", "settings.gradle", "pom.xml"],
            sourceExtensions: ["kt"], relevance: .markerAndSources,
            prerequisite: "JDK 17+",
            installInstructions: ["brew install JetBrains/utils/kotlin-lsp"],
            installURL: "https://github.com/Kotlin/kotlin-lsp",
            licence: "JetBrains' official server, alpha. Read the repository's licence before redistributing.",
            notes: "Independent of Umbra's native Java engine: a Gradle or Maven project with Kotlin sources gets both.",
            diagnosticSource: DiagnosticSourceID(rawValue: "kotlin-lsp")
        ),
        IDELanguageServerSpec(
            id: "metals", displayName: "Scala", languageIDs: ["scala"],
            executables: ["metals"],
            versionArguments: nil,
            projectMarkers: ["build.sbt", "build.sc", "project.scala"], sourceExtensions: ["scala", "sc"],
            extraSearchDirectories: ["~/Library/Application Support/Coursier/bin", "~/.local/share/coursier/bin"],
            prerequisite: "JDK 17+ and a build tool (sbt, Mill, scala-cli)",
            installInstructions: ["cs install metals", "brew install coursier/formulas/coursier && cs setup"],
            installURL: "https://scalameta.org/metals/docs/editors/new-editor",
            licence: "Apache-2.0",
            notes: "Imports the build on first open, which can take minutes. The editor stays responsive meanwhile.",
            initializationOptions: #"{"isHttpEnabled":false,"statusBarProvider":"off"}"#,
            diagnosticSource: DiagnosticSourceID(rawValue: "metals")
        ),
        IDELanguageServerSpec(
            id: "zls", displayName: "Zig", languageIDs: ["zig"],
            executables: ["zls"],
            projectMarkers: ["build.zig", "build.zig.zon"], sourceExtensions: ["zig"],
            prerequisite: "Zig compiler matching the ZLS release",
            installInstructions: ["brew install zls"],
            installURL: "https://zigtools.org/zls/install/",
            licence: "MIT",
            notes: "ZLS must match the Zig version. Single files work without `build.zig`.",
            diagnosticSource: DiagnosticSourceID(rawValue: "zls")
        ),
        IDELanguageServerSpec(
            id: "terraform-ls", displayName: "Terraform", languageIDs: ["terraform"],
            lspLanguageIDs: ["terraform": "terraform"],
            executables: ["terraform-ls"], arguments: ["serve"],
            versionArguments: ["version"],
            projectMarkers: ["*.tf", "*.tf.json"], sourceExtensions: ["tf", "tfvars"],
            prerequisite: "Terraform CLI (for provider schemas)",
            installInstructions: ["brew install hashicorp/tap/terraform-ls"],
            installURL: "https://github.com/hashicorp/terraform-ls",
            licence: "MPL-2.0 (HashiCorp relicensed other products; confirm the repository before redistributing).",
            diagnosticSource: DiagnosticSourceID(rawValue: "terraform-ls")
        ),
        IDELanguageServerSpec(
            id: "ruby-lsp", displayName: "Ruby", languageIDs: ["ruby"],
            executables: ["ruby-lsp"],
            projectMarkers: ["Gemfile", "*.gemspec"], sourceExtensions: ["rb"],
            projectLocalPaths: ["bin/ruby-lsp"],
            extraSearchDirectories: ["~/.rbenv/shims", "~/.asdf/shims", "~/.local/share/mise/shims", "/opt/homebrew/opt/ruby/bin"],
            prerequisite: "Ruby 3.0+",
            installInstructions: ["gem install ruby-lsp", "bundle add ruby-lsp --group development"],
            installURL: "https://shopify.github.io/ruby-lsp/",
            licence: "MIT",
            notes: "Ruby LSP builds its own composed Bundler environment under `.ruby-lsp/` in the project.",
            initializationOptions: #"{"enabledFeatures":{"diagnostics":true,"formatting":true}}"#,
            diagnosticSource: DiagnosticSourceID(rawValue: "ruby-lsp")
        ),
        IDELanguageServerSpec(
            id: "r-languageserver", displayName: "R", languageIDs: ["r"],
            executables: ["R"], arguments: ["--no-echo", "--no-save", "-e", "languageserver::run()"],
            projectMarkers: ["DESCRIPTION", "*.Rproj"], sourceExtensions: ["r"],
            extraSearchDirectories: ["/Library/Frameworks/R.framework/Resources/bin"],
            prerequisite: "R with the `languageserver` package",
            installInstructions: ["brew install r", #"R -e 'install.packages("languageserver")'"#],
            installURL: "https://github.com/REditorSupport/languageserver",
            licence: "GPL-3.0 (run as a separate process; nothing is linked into Umbra).",
            notes: "A missing `languageserver` package makes R exit; the status then reads restarting, then the server is parked by the restart limit.",
            diagnosticSource: DiagnosticSourceID(rawValue: "r-languageserver")
        ),
        IDELanguageServerSpec(
            id: "lua-language-server", displayName: "Lua", languageIDs: ["lua"],
            executables: ["lua-language-server"],
            projectMarkers: [".luarc.json", ".luarc.jsonc"], sourceExtensions: ["lua"],
            prerequisite: "None (self-contained binary)",
            installInstructions: ["brew install lua-language-server"],
            installURL: "https://luals.github.io/#install",
            licence: "MIT",
            notes: "Without `.luarc.json` it analyses the opened folder as a Lua 5.4 workspace.",
            diagnosticSource: DiagnosticSourceID(rawValue: "lua-ls")
        ),
        IDELanguageServerSpec(
            id: "gopls", displayName: "Go", languageIDs: ["go"],
            executables: ["gopls"],
            versionArguments: ["version"],
            projectMarkers: ["go.mod", "go.work"], sourceExtensions: ["go"],
            extraSearchDirectories: ["~/go/bin", "/usr/local/go/bin"],
            prerequisite: "Go toolchain",
            installInstructions: ["go install golang.org/x/tools/gopls@latest", "brew install gopls"],
            installURL: "https://go.dev/gopls/",
            licence: "BSD-3-Clause",
            diagnosticSource: DiagnosticSourceID(rawValue: "gopls")
        ),
        IDELanguageServerSpec(
            id: "dart-analysis-server", displayName: "Dart", languageIDs: ["dart"],
            executables: ["dart"], arguments: ["language-server", "--protocol=lsp"],
            projectMarkers: ["pubspec.yaml"], sourceExtensions: ["dart"],
            extraSearchDirectories: ["/opt/homebrew/opt/dart/libexec/bin", "~/flutter/bin/cache/dart-sdk/bin", "~/fvm/default/bin/cache/dart-sdk/bin"],
            prerequisite: "Dart SDK (or Flutter)",
            installInstructions: ["brew tap dart-lang/dart && brew install dart"],
            installURL: "https://dart.dev/get-dart",
            licence: "BSD-3-Clause",
            notes: "The server is a subcommand of the SDK's `dart`, not a separate binary.",
            diagnosticSource: DiagnosticSourceID(rawValue: "dart-analysis")
        ),
        IDELanguageServerSpec(
            id: "clangd", displayName: "C and C++", languageIDs: ["c", "cpp"],
            executables: ["clangd"], arguments: ["--background-index", "--clang-tidy=false"],
            projectMarkers: ["compile_commands.json", "compile_flags.txt", ".clangd", "CMakeLists.txt", "meson.build"],
            sourceExtensions: ["c", "cc", "cpp", "cxx", "h", "hpp"], relevance: .sources,
            extraSearchDirectories: ["/Library/Developer/CommandLineTools/usr/bin", "/opt/homebrew/opt/llvm/bin"],
            prerequisite: "Xcode Command Line Tools or LLVM",
            installInstructions: ["xcode-select --install", "brew install llvm"],
            installURL: "https://clangd.llvm.org/installation",
            licence: "Apache-2.0 with LLVM exceptions",
            notes: "One clangd serves both languages in a workspace. It needs `compile_commands.json` for accurate results (CMake: `-DCMAKE_EXPORT_COMPILE_COMMANDS=ON`).",
            diagnosticSource: DiagnosticSourceID(rawValue: "clangd")
        ),
        IDELanguageServerSpec(
            id: "bash-language-server", displayName: "Bash", languageIDs: ["shell"],
            lspLanguageIDs: ["shell": "shellscript"],
            executables: ["bash-language-server"], arguments: ["start"],
            projectMarkers: [".shellcheckrc"], sourceExtensions: ["sh", "bash"],
            projectLocalPaths: ["node_modules/.bin/bash-language-server"],
            prerequisite: "Node.js; ShellCheck and shfmt are optional and add diagnostics and formatting",
            installInstructions: ["npm install -g bash-language-server", "brew install shellcheck shfmt"],
            installURL: "https://github.com/bash-lsp/bash-language-server",
            licence: "MIT",
            notes: "Extensionless scripts with a shebang are not detected as shell files by Umbra yet.",
            diagnosticSource: DiagnosticSourceID(rawValue: "bash-language-server")
        ),
    ]

    static func spec(id: String) -> IDELanguageServerSpec? { all.first { $0.id == id } }

    /// The spec that answers `languageID`, for Settings and status.
    static func spec(forLanguage languageID: String) -> IDELanguageServerSpec? {
        all.first { $0.languageIDs.contains(languageID) }
    }
}
