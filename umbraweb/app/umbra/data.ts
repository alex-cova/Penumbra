/** Fixtures for the Umbra window mock. Everything here is made up for this page. */

export type Lang = "java" | "swift" | "gradle" | "md" | "http" | "yaml" | "sql" | "py" | "html" | "json" | "text";
export type Kind = "code" | "md" | "hex" | "jfr";

export type FileSpec = {
  id: string;
  path: string;
  lang: Lang;
  kind: Kind;
  language: string;
  symbols: string[];
  line: number;
  col: number;
  body: string;
};

const code = (
  id: string,
  path: string,
  lang: Lang,
  language: string,
  symbols: string[],
  line: number,
  col: number,
  body: string,
): FileSpec => ({ id, path, lang, kind: "code", language, symbols, line, col, body });

export const FILES: FileSpec[] = [
  code("Greeter.java", "src/main/java/app/Greeter.java", "java", "Java", ["Greeter", "name", "greet", "greetLoud"], 12, 33, `package app;

public final class Greeter {
    private final String name;

    public Greeter(String name) {
        this.name = name;
    }

    public String greet() {
        // Tree-sitter colours this comment.
        return "Hello, " + name;
    }

    public String greetLoud() {
        return greet().toUpperCase();
    }

    @Override
    public String toString() {
        return "Greeter(" + name + ")";
    }
}`),
  code("App.java", "src/main/java/app/App.java", "java", "Java", ["App", "main"], 8, 9, `package app;

public final class App {
    private App() {
    }

    public static void main(String[] args) {
        String who = args.length == 0 ? "Ada" : String.join(" ", args);
        Greeter greeter = new Greeter(who);
        System.out.println(greeter.greet());
    }
}`),
  code("ContentView.swift", "Sources/ContentView.swift", "swift", "Swift", ["ContentView", "body", "greeting"], 9, 16, `import SwiftUI

struct ContentView: View {
    private let name = "Ada"

    var body: some View {
        Text(greeting)
            .font(.body)
            .padding()
    }

    private var greeting: String {
        "Hello, \\(name)"
    }
}

#Preview {
    ContentView()
}`),
  {
    id: "README.md",
    path: "README.md",
    lang: "md",
    kind: "md",
    language: "Markdown",
    symbols: ["Ledger", "Run it"],
    line: 1,
    col: 9,
    body: `# Ledger

Greeter.greet builds the line the program prints.

## Run it

- Run ./gradlew run from this folder.
- Edit Greeter.java and run again.

Flow: Start, Greeter.greet, print.`,
  },
  code("notes.http", "notes.http", "http", "HTTP", ["GET", "POST"], 1, 5, `GET https://example.com/health
Accept: application/json

###

POST https://example.com/greet
Content-Type: application/json

{
  "name": "Ada"
}`),
  code("build.gradle", "build.gradle", "gradle", "Gradle", ["plugins", "application"], 6, 5, `plugins {
    id "application"
}

repositories {
    mavenCentral()
}

dependencies {
    testImplementation "org.junit.jupiter:junit-jupiter:5.11.4"
}

application {
    mainClass = "app.App"
}`),
  code("config.yaml", "config.yaml", "yaml", "YAML", ["name"], 2, 7, `name: ledger
greeting: Hello
count: 3`),
  code("schema.sql", "schema.sql", "sql", "SQL", ["notes"], 1, 13, `select id, body
from notes
where author = 'Ada';`),
  code("main.py", "main.py", "py", "Python", ["greet"], 1, 5, `def greet(name):
    return "Hello, " + name

print(greet("Ada"))`),
  { id: "app.jfr", path: "profiles/app.jfr", lang: "text", kind: "jfr", language: "JFR", symbols: [], line: 1, col: 1, body: "" },
  { id: "ledger.bin", path: "build/ledger.bin", lang: "text", kind: "hex", language: "Binary", symbols: [], line: 1, col: 1, body: "" },
];

export const OPEN_AT_START = ["Greeter.java", "App.java", "ContentView.swift", "README.md"];

export function fileById(id: string) {
  return FILES.find((file) => file.id === id) ?? FILES[0];
}

/* ---- explorer tree ---- */
export type TreeNode = { name: string; file?: string; children?: TreeNode[] };
export const TREE: TreeNode = {
  name: "ledger",
  children: [
    { name: "build", children: [{ name: "ledger.bin", file: "ledger.bin" }] },
    { name: "profiles", children: [{ name: "app.jfr", file: "app.jfr" }] },
    {
      name: "src",
      children: [
        {
          name: "main",
          children: [{ name: "java", children: [{ name: "app", children: [{ name: "Greeter.java", file: "Greeter.java" }, { name: "App.java", file: "App.java" }] }] }],
        },
      ],
    },
    { name: "Sources", children: [{ name: "ContentView.swift", file: "ContentView.swift" }] },
    { name: "README.md", file: "README.md" },
    { name: "notes.http", file: "notes.http" },
    { name: "build.gradle", file: "build.gradle" },
    { name: "config.yaml", file: "config.yaml" },
    { name: "schema.sql", file: "schema.sql" },
    { name: "main.py", file: "main.py" },
  ],
};

/* ---- hex: a small made-up file, 512 bytes ---- */
export const HEX_BYTES: number[] = (() => {
  const out: number[] = [];
  const text = (s: string) => [...s].forEach((c) => out.push(c.charCodeAt(0)));
  out.push(0x4c, 0x45, 0x44, 0x47, 0x00, 0x01, 0x00, 0x00);
  for (let i = 0; i < 4; i++) out.push(0, 0, 0, i + 1);
  text("ledger\u0000Greeter\u0000greet\u0000Hello, Ada\u0000");
  let seed = 7;
  while (out.length < 512) {
    seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0;
    const byte = (seed >>> 16) & 0xff;
    out.push(byte % 6 === 0 ? 0 : byte);
  }
  return out.slice(0, 512);
})();

/* ---- flame graph ---- */
export type Frame = { name: string; value: number; origin: "java" | "native" | "jit" | "other"; children?: Frame[] };
export const FLAME: Frame = {
  name: "all",
  value: 100,
  origin: "other",
  children: [
    {
      name: "app.App.main",
      value: 78,
      origin: "java",
      children: [
        {
          name: "app.Greeter.greet",
          value: 52,
          origin: "java",
          children: [
            { name: "java.lang.String.concat", value: 31, origin: "java", children: [{ name: "java.lang.StringConcatHelper.newArray", value: 14, origin: "java" }, { name: "jdk.internal.misc.Unsafe.allocateUninitializedArray", value: 9, origin: "java" }] },
            { name: "java.lang.StringBuilder.append", value: 15, origin: "java" },
          ],
        },
        { name: "java.io.PrintStream.println", value: 21, origin: "java", children: [{ name: "java.io.BufferedWriter.write", value: 12, origin: "java" }, { name: "write", value: 7, origin: "native" }] },
      ],
    },
    { name: "java.lang.Thread.run", value: 14, origin: "java", children: [{ name: "app.Greeter.greetLoud", value: 9, origin: "java" }] },
    { name: "C2 Compiler", value: 8, origin: "jit" },
  ],
};

/* ---- git ---- */
export type Commit = { id: string; msg: string; who: string; when: string; parents: string[]; files: { name: string; add: number; del: number }[]; diff: string[] };
export const COMMITS: Commit[] = [
  { id: "a819bfe", msg: "greet loudly", who: "alex", when: "2 days ago", parents: ["f00918c"], files: [{ name: "Greeter.java", add: 5, del: 0 }], diff: ["@@ -11,6 +11,10 @@", " public String greet() {", "     return \"Hello, \" + name;", " }", "+", "+    public String greetLoud() {", "+        return greet().toUpperCase();", "+    }"] },
  { id: "f00918c", msg: "print through App", who: "alex", when: "5 days ago", parents: ["47d837e"], files: [{ name: "App.java", add: 3, del: 1 }], diff: ["@@ -6,5 +6,7 @@", "-        System.out.println(\"hi\");", "+        Greeter greeter = new Greeter(who);", "+        System.out.println(greeter.greet());"] },
  { id: "47d837e", msg: "Merge branch 'config'", who: "alex", when: "1 week ago", parents: ["768e993", "8e76b76"], files: [{ name: "config.yaml", add: 3, del: 0 }], diff: ["@@ -0,0 +1,3 @@", "+name: ledger", "+greeting: Hello", "+count: 3"] },
  { id: "8e76b76", msg: "add config.yaml", who: "ada", when: "1 week ago", parents: ["a41147c"], files: [{ name: "config.yaml", add: 3, del: 0 }], diff: ["@@ -0,0 +1,3 @@", "+name: ledger", "+greeting: Hello"] },
  { id: "a41147c", msg: "README", who: "ada", when: "2 weeks ago", parents: ["768e993"], files: [{ name: "README.md", add: 5, del: 0 }], diff: ["@@ -0,0 +1,5 @@", "+# Ledger", "+", "+Greeter.greet builds the line the program prints."] },
  { id: "768e993", msg: "first commit", who: "alex", when: "3 weeks ago", parents: [], files: [{ name: "build.gradle", add: 14, del: 0 }], diff: ["@@ -0,0 +1,3 @@", "+plugins {", "+    id \"application\"", "+}"] },
];

export const CHANGES = [
  { name: "Greeter.java", path: "src/main/java/app/" },
  { name: "App.java", path: "src/main/java/app/" },
  { name: "README.md", path: "" },
];

/* ---- build tool: the project is Java, so the sidebar tab is Gradle (SwiftPM for a Swift package) ---- */
export const PROJECT: "java" | "swift" = "java";
export const SWIFTPM: { name: string; count?: number; tasks?: string[] }[] = [
  { name: "Targets", count: 2, tasks: ["Ledger (executable)", "LedgerTests"] },
  { name: "Dependencies", count: 1, tasks: ["swift-argument-parser 1.5.0"] },
  { name: "Products", count: 1, tasks: ["ledger"] },
];

/* ---- gradle ---- */
export const GRADLE: { name: string; count?: number; tasks?: string[] }[] = [
  { name: "build", count: 13, tasks: ["assemble", "build", "classes", "clean", "jar"] },
  { name: "verification", count: 3, tasks: ["check", "test"] },
  { name: "application", count: 1, tasks: ["run"] },
  { name: "help", count: 12, tasks: ["tasks", "dependencies"] },
];

/* ---- terminal ---- */
export const TERMINAL_HELP = ["ls", "pwd", "git status", "./gradlew run", "clear"];
export function terminal(cmd: string): string[] | "clear" {
  switch (cmd.trim()) {
    case "":
      return [];
    case "ls":
      return ["README.md  Sources  build  build.gradle  config.yaml  main.py  notes.http  profiles  schema.sql  src"];
    case "pwd":
      return ["/Users/alex/ledger"];
    case "git status":
      return ["On branch main", "Changes not staged for commit:", "\tmodified:   src/main/java/app/Greeter.java", "\tmodified:   src/main/java/app/App.java", "\tmodified:   README.md"];
    case "./gradlew run":
      return ["> Task :compileJava", "> Task :run", "Hello, Ada", "", "BUILD SUCCESSFUL in 1s", "3 actionable tasks: 3 executed"];
    case "clear":
      return "clear";
    case "help":
      return ["try: " + TERMINAL_HELP.join(", ")];
    default:
      return [`zsh: command not found: ${cmd.trim().split(" ")[0]}`];
  }
}

/* ---- agent ---- */
export const AGENT_PROMPT = "Add Javadoc to Greeter";
export const AGENT_TEXT = [
  "Greeter builds the line the program prints, and greet() is the only method App calls.",
  "I'll add a class comment and one on greet(), in the style the project already uses.",
];
export const AGENT_DONE = "Done. I added Javadoc to Greeter, based on how App uses it. Diagnostics report no errors or warnings.";
export const AGENT_CANNED = "That is outside this demo's script, but the real agent would read the files it needs, edit them in your open tab and let you revert the run.";
export const AGENT_EDIT = {
  find: "public final class Greeter {",
  add: "/** Builds the greeting the program prints. */\npublic final class Greeter {",
};
