import type { Lang } from "./data";

const KEYS: Record<Lang, string[]> = {
  java: ["package", "import", "public", "private", "protected", "final", "class", "interface", "return", "new", "static", "void", "this", "if", "else", "int", "boolean", "String"],
  swift: ["import", "struct", "var", "let", "func", "return", "some", "private"],
  gradle: ["plugins", "repositories", "dependencies", "implementation", "testImplementation", "id"],
  md: [],
  http: ["GET", "POST", "Accept", "Content-Type"],
  yaml: [],
  sql: ["select", "from", "where", "insert", "into", "values"],
  py: ["def", "return", "import", "from", "class", "print"],
  html: [],
  json: [],
  text: [],
};
const BASIC = new Set(["int", "boolean", "String", "void"]);

export type Part = { kind: "p" | "k" | "ty" | "s" | "c" | "f" | "n" | "a" | "m"; text: string };

export function paint(line: string, lang: Lang): Part[] {
  if (lang === "md" && line.startsWith("#")) return [{ kind: "f", text: line }];
  const keys = KEYS[lang];
  const keyPart = keys.length ? String.raw`|\b(?:${keys.join("|")})\b` : "";
  const pattern = new RegExp(
    String.raw`(\/\/.*$|\/\*.*?\*\/|#(?! ).*$|"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|@[A-Za-z]+${keyPart}|\b[a-z_][A-Za-z0-9_]*(?=\()|\b[A-Z][A-Za-z0-9_]*|\b\d+\b)`,
    "g",
  );
  const parts: Part[] = [];
  let cursor = 0;
  for (const match of line.matchAll(pattern)) {
    const index = match.index ?? 0;
    if (index > cursor) parts.push({ kind: "p", text: line.slice(cursor, index) });
    const text = match[0];
    let kind: Part["kind"] = "p";
    if (text.startsWith("//") || text.startsWith("/*") || text.startsWith("#")) kind = "c";
    else if (text.startsWith('"') || text.startsWith("'")) kind = "s";
    else if (text.startsWith("@")) kind = "a";
    else if (keys.includes(text)) kind = BASIC.has(text) ? "ty" : "k";
    else if (/^[A-Z]/.test(text)) kind = "ty";
    else if (/^\d/.test(text)) kind = "n";
    else if (/^[a-z_]/.test(text)) kind = "m";
    parts.push({ kind, text });
    cursor = index + text.length;
  }
  if (cursor < line.length) parts.push({ kind: "p", text: line.slice(cursor) });
  return parts;
}

const MODS = "(?:(?:public|private|protected|final|static|abstract|default|synchronized)\\s+)";
export function isMemberStart(line: string, lang: Lang) {
  if (/^\s*@/.test(line)) return false;
  if (lang === "java") {
    if (new RegExp(`^\\s*${MODS}*(class|interface|enum|record)\\b`).test(line)) return true;
    return new RegExp(`^\\s*${MODS}+[\\w<>\\[\\].,? ]+\\s+\\w+\\s*\\(`).test(line);
  }
  if (lang === "swift") return /^\s*(?:(?:private|fileprivate|internal|public|open|final|static|override|mutating)\s+)*(func|var|let|struct|class|enum|init)\b/.test(line);
  if (lang === "py") return /^(def |class |async def )/.test(line);
  return false;
}

/** Rows that open a member block; annotations above a member belong to it. */
export function memberSeparators(lines: string[], lang: Lang) {
  const seps = new Set<number>();
  lines.forEach((line, index) => {
    if (!isMemberStart(line, lang)) return;
    let first = index;
    while (first > 0 && /^\s*@/.test(lines[first - 1])) first--;
    if (first > 0 && lines[first - 1].trim() === "") seps.add(first);
    else if (first > 0) seps.add(first);
  });
  return seps;
}
