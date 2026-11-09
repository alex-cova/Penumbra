"use client";

import { useState } from "react";
import { CHANGES, FILES, TREE, fileById, type FileSpec, type TreeNode } from "./data";
import { Branch, Check, Chevron, Dot, FileIcon, Folder, List, Plus } from "./icons";

export type SideTab = "explorer" | "structure" | "changes" | "breakpoints";
const TABS: [SideTab, string, React.ReactNode][] = [
  ["explorer", "Explorer", <Folder key="e" />],
  ["structure", "Structure", <List key="s" />],
  ["changes", "Changes", <Branch key="c" />],
    ["breakpoints", "Breakpoints", <Dot key="d" />],
];

function Node({ node, depth, active, opened, onOpen }: { node: TreeNode; depth: number; active: string; opened: string[]; onOpen: (id: string) => void }) {
  const [open, setOpen] = useState(depth < 1 || ["src", "main", "java", "app"].includes(node.name));
  const pad = { paddingLeft: 8 + depth * 14 };
  if (node.file) {
    const file = fileById(node.file);
    return (
      <li>
        <button type="button" style={pad} className={opened.includes(file.id) ? "is-open" : undefined} aria-current={file.id === active ? "true" : undefined} onClick={() => onOpen(file.id)}>
          <span className="sp" />
          <FileIcon kind={file.kind} lang={file.lang} />
          <span className="nm">{node.name}</span>
        </button>
      </li>
    );
  }
  return (
    <li>
      <button type="button" style={pad} aria-expanded={open} onClick={() => setOpen((v) => !v)}>
        <Chevron open={open} />
        <Folder />
        <span className="nm">{node.name}</span>
      </button>
      {open ? (
        <ul>
          {node.children?.map((child) => (
            <Node key={child.name} node={child} depth={depth + 1} active={active} opened={opened} onOpen={onOpen} />
          ))}
        </ul>
      ) : null}
    </li>
  );
}

export function Changes({
  staged,
  message,
  onMessage,
  onToggle,
  onCommit,
  committed,
}: {
  staged: string[];
  message: string;
  onMessage: (v: string) => void;
  onToggle: (name: string) => void;
  onCommit: () => void;
  committed: string[];
}) {
  const left = CHANGES.filter((c) => !committed.includes(c.name));
  const stagedRows = left.filter((c) => staged.includes(c.name));
  const rest = left.filter((c) => !staged.includes(c.name));
  const row = (c: (typeof CHANGES)[number], on: boolean) => (
    <li key={c.name}>
      <button type="button" onClick={() => onToggle(c.name)} aria-label={`${on ? "Unstage" : "Stage"} ${c.name}`}>
        <span className="tg">{on ? <Check /> : <Plus />}</span>
        <span className="nm">{c.name}</span>
        <small>{c.path}</small>
        <span className="m">M</span>
      </button>
    </li>
  );
  return (
    <div className="umbra-changes">
      <textarea value={message} onChange={(e) => onMessage(e.target.value)} placeholder="Commit message, press ⌘↩ to commit" aria-label="Commit message" rows={2} />
      <button type="button" className="umbra-commit" disabled={!message.trim() || stagedRows.length === 0} onClick={onCommit}>
        Commit
      </button>
      <h4>Staged changes ({stagedRows.length})</h4>
      <ul>{stagedRows.map((c) => row(c, true))}</ul>
      <h4>Changes ({rest.length})</h4>
      <ul>{rest.map((c) => row(c, false))}</ul>
      {left.length === 0 ? <p>Working tree clean</p> : null}
    </div>
  );
}

export function Sidebar({
  tab,
  onTab,
  file,
  opened,
  onOpen,
  changes,
}: {
  tab: SideTab;
  onTab: (t: SideTab) => void;
  file: FileSpec;
  opened: string[];
  onOpen: (id: string) => void;
  changes: React.ReactNode;
}) {
  return (
    <div className="umbra-side umbra-card">
      <div className="umbra-side-tabs" role="tablist" aria-label="Sidebar">
        {TABS.map(([id, label, icon]) => (
          <button key={id} type="button" role="tab" aria-selected={tab === id} aria-label={label} title={label} onClick={() => onTab(id)}>
            {icon}
            {tab === id ? <span>{label}</span> : null}
          </button>
        ))}
      </div>
      <div className="umbra-side-body">
        {tab === "explorer" ? (
          <ul className="umbra-tree">
            <Node node={TREE} depth={0} active={file.id} opened={opened} onOpen={onOpen} />
          </ul>
        ) : null}
        {tab === "structure" ? (
          file.symbols.length ? (
            <ul className="umbra-tree">
              {file.symbols.map((s) => (
                <li key={s}>
                  <span className="umbra-sym">{s}</span>
                </li>
              ))}
            </ul>
          ) : (
            <p className="umbra-empty">No symbols in {file.id}</p>
          )
        ) : null}
        {tab === "changes" ? changes : null}
        {tab === "breakpoints" ? <p className="umbra-empty">No breakpoints</p> : null}
      </div>
    </div>
  );
}
void FILES;
