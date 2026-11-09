"use client";

import { useRef, useState } from "react";
import { AgentPane } from "./AgentPane";
import { BUILD_LABEL, BuildPane } from "./BuildPane";
import { PreviewPane } from "./PreviewPane";
import { BottomPanel, type BottomTab } from "./BottomPanel";
import { type Cursor } from "./Buffer";
import { AGENT_EDIT, FILES, OPEN_AT_START, fileById } from "./data";
import { EditorCard, Status } from "./EditorCard";
import { Changes, Sidebar, type SideTab } from "./Sidebar";
import { TitleBar } from "./TitleBar";
import { GitHistory } from "./views/GitHistory";
import "../umbra-window.css";

type Phone = "editor" | "files" | "build" | "agent" | "terminal";
type Added = { id: string; msg: string; files: string[] };

const initialText = Object.fromEntries(FILES.map((f) => [f.id, f.body]));
const initialCursor: Record<string, Cursor> = Object.fromEntries(FILES.map((f) => [f.id, { line: f.line, col: f.col, selected: 0 }]));

export function UmbraWindow() {
  const [active, setActive] = useState("Greeter.java");
  const [opened, setOpened] = useState(OPEN_AT_START);
  const [texts, setTexts] = useState(initialText);
  const [saved, setSaved] = useState(initialText);
  const [cursors, setCursors] = useState(initialCursor);
  const [side, setSide] = useState(true);
  const [bottom, setBottom] = useState(false);
  const [right, setRight] = useState(false);
  const [mode, setMode] = useState<"build" | "agent" | "preview">("build");
  const [sideTab, setSideTab] = useState<SideTab>("explorer");
  const [bottomTab, setBottomTab] = useState<BottomTab>("terminal");
  const [preview, setPreview] = useState(false);
  const [phone, setPhone] = useState<Phone>("editor");
  const [staged, setStaged] = useState<string[]>([]);
  const [message, setMessage] = useState("");
  const [commits, setCommits] = useState<Added[]>([]);
  const before = useRef<string | null>(null);

  const file = fileById(active);
  const isText = file.kind === "code" || file.kind === "md";
  const dirty = (id: string) => texts[id] !== saved[id];
  const committed = commits.flatMap((c) => c.files);

  function open(id: string) {
    if (fileById(id).lang === "swift") {
      setRight(true);
      setMode("preview");
    }
    setActive(id);
    setOpened((cur) => (cur.includes(id) ? cur : [...cur, id]));
    setPhone("editor");
  }
  function close(id: string) {
    if (opened.length < 2) return;
    const next = opened.filter((o) => o !== id);
    setOpened(next);
    if (active === id) setActive(next[next.length - 1]);
  }
  function closeOthers(id: string) {
    if (!opened.includes(id)) return;
    setOpened([id]);
    setActive(id);
  }
  function closeToRight(id: string) {
    const index = opened.indexOf(id);
    if (index === -1 || index === opened.length - 1) return;
    const next = opened.slice(0, index + 1);
    setOpened(next);
    if (!next.includes(active)) setActive(id);
  }
  function closeAll() {
    setOpened([]);
  }
  function show(p: Phone) {
    setPhone(p);
    if (p === "files") setSide(true);
    if (p === "build") {
      setRight(true);
      setMode("build");
    }
    if (p === "agent") {
      setRight(true);
      setMode(file.lang === "swift" ? "preview" : "agent");
    }
    if (p === "terminal") {
      setBottom(true);
      setBottomTab("terminal");
    }
  }
  function commit() {
    const files = staged.filter((s) => !committed.includes(s));
    setCommits((c) => [{ id: Math.random().toString(16).slice(2, 9), msg: message.trim(), files }, ...c]);
    setStaged([]);
    setMessage("");
    setBottom(true);
    setBottomTab("history");
  }

  return (
    <div
      className={["umbra-win", side ? "" : "no-side", right ? "has-right" : ""].join(" ").trim()}
      data-phone={phone === "build" ? "agent" : phone}
      role="group"
      aria-label="Umbra window, interactive"
      onKeyDown={(e) => {
        if ((e.metaKey || e.ctrlKey) && e.key === "s") {
          e.preventDefault();
          setSaved((s) => ({ ...s, [active]: texts[active] }));
        }
      }}
    >
      <TitleBar
        side={side}
        bottom={bottom}
        right={right}
        onSide={() => setSide((v) => !v)}
        onBottom={() => setBottom((v) => !v)}
        onRight={() => {
          if (right) setRight(false);
          else {
            setMode("build");
            setRight(true);
          }
        }}
        preview={file.kind === "md" ? preview : null}
        onPreview={() => setPreview((v) => !v)}
        mode={mode}
        swift={file.lang === "swift"}
        onAgent={() => {
          setRight(!(right && mode === "agent"));
          setMode("agent");
        }}
        onSwiftPreview={() => {
          setRight(!(right && mode === "preview"));
          setMode("preview");
        }}
      />
      <div className="umbra-phone" role="tablist" aria-label="Panes">
        {(["editor", "files", "build", "agent", "terminal"] as Phone[]).map((p) => (
          <button key={p} type="button" role="tab" aria-selected={phone === p} onClick={() => show(p)}>
            {p === "editor" ? "Editor" : p === "files" ? "Files" : p === "build" ? BUILD_LABEL : p === "agent" ? (file.lang === "swift" ? "Preview" : "Agent") : "Terminal"}
          </button>
        ))}
      </div>
      {side ? (
        <Sidebar
          tab={sideTab}
          onTab={setSideTab}
          file={file}
          opened={opened}
          onOpen={open}
          changes={
            <Changes
              staged={staged}
              message={message}
              onMessage={setMessage}
              onToggle={(n) => setStaged((s) => (s.includes(n) ? s.filter((x) => x !== n) : [...s, n]))}
              onCommit={commit}
              committed={committed}
            />
          }
        />
      ) : null}
      <div className="umbra-main">
        <EditorCard
          file={file}
          opened={opened}
          dirty={dirty}
          text={texts[active]}
          cursor={cursors[active]}
          preview={preview}
          onSelect={setActive}
          onClose={close}
          onCloseOthers={closeOthers}
          onCloseToRight={closeToRight}
          onCloseAll={closeAll}
          onText={(v) => setTexts((t) => ({ ...t, [active]: v }))}
          onCursor={(c) => setCursors((cs) => ({ ...cs, [active]: c }))}
        />
        {bottom ? <BottomPanel tab={bottomTab} onTab={setBottomTab} history={<GitHistory added={commits} />} /> : null}
      </div>
      {right && (mode === "build" || (mode === "preview" && file.lang !== "swift")) ? <BuildPane /> : null}
      {right && mode === "preview" && file.lang === "swift" ? <PreviewPane source={texts[active]} /> : null}
      {right && mode === "agent" ? (
        <AgentPane
          onEdit={() => {
            setActive("Greeter.java");
            setOpened((cur) => (cur.includes("Greeter.java") ? cur : [...cur, "Greeter.java"]));
            setTexts((t) => {
              before.current = t["Greeter.java"];
              return { ...t, "Greeter.java": t["Greeter.java"].replace(AGENT_EDIT.find, AGENT_EDIT.add) };
            });
          }}
          onRevert={() => {
            const prev = before.current;
            if (prev !== null) setTexts((t) => ({ ...t, "Greeter.java": prev }));
          }}
        />
      ) : null}
      <Status file={file} cursor={cursors[active]} dirty={isText && dirty(active)} bottomOn={bottom} onTerminal={() => { setBottom((v) => !v); setBottomTab("terminal"); }} />
    </div>
  );
}
