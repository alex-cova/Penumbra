"use client";

import { useEffect, useRef, useState } from "react";
import { Buffer, type Cursor } from "./Buffer";
import { fileById, type FileSpec } from "./data";
import { Close, FileIcon } from "./icons";
import { Flame } from "./views/Flame";
import { Hex } from "./views/Hex";
import { Markdown } from "./views/Markdown";

export function EditorCard({
  file,
  opened,
  dirty,
  text,
  cursor,
  preview,
  onSelect,
  onClose,
  onCloseOthers,
  onCloseToRight,
  onCloseAll,
  onText,
  onCursor,
}: {
  file: FileSpec;
  opened: string[];
  dirty: (id: string) => boolean;
  text: string;
  cursor: Cursor;
  preview: boolean;
  onSelect: (id: string) => void;
  onClose: (id: string) => void;
  onCloseOthers: (id: string) => void;
  onCloseToRight: (id: string) => void;
  onCloseAll: () => void;
  onText: (v: string) => void;
  onCursor: (c: Cursor) => void;
}) {
  const [menu, setMenu] = useState<{ id: string; x: number; y: number } | null>(null);
  const menuRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (!menu) return;
    const onPointer = (e: PointerEvent) => {
      if (menuRef.current && !menuRef.current.contains(e.target as Node)) setMenu(null);
    };
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") setMenu(null);
    };
    window.addEventListener("pointerdown", onPointer);
    window.addEventListener("keydown", onKey);
    return () => {
      window.removeEventListener("pointerdown", onPointer);
      window.removeEventListener("keydown", onKey);
    };
  }, [menu]);

  const menuIndex = menu ? opened.indexOf(menu.id) : -1;

  function act(fn: () => void) {
    fn();
    setMenu(null);
  }

  return (
    <div className="umbra-editor umbra-card">
      <div className="umbra-tabs" role="tablist" aria-label="Open files">
        {opened.map((id) => {
          const item = fileById(id);
          const on = id === file.id;
          return (
            <span
              key={id}
              className={on ? "umbra-tab is-on" : "umbra-tab"}
              onContextMenu={(e) => {
                e.preventDefault();
                setMenu({ id, x: e.clientX, y: e.clientY });
              }}
            >
              <button type="button" role="tab" aria-selected={on} className="umbra-tab__name" onClick={() => onSelect(id)}>
                <FileIcon kind={item.kind} lang={item.lang} />
                {item.id}
                {dirty(id) ? <i className="umbra-dirty" aria-label="Unsaved changes" /> : null}
              </button>
              {opened.length > 1 ? (
                <button type="button" className="umbra-tab__x" aria-label={`Close ${item.id}`} onClick={() => onClose(id)}>
                  <Close />
                </button>
              ) : null}
            </span>
          );
        })}
      </div>
      {menu && menuIndex !== -1 ? (
        <div
          ref={menuRef}
          className="umbra-tabmenu"
          role="menu"
          aria-label={`Tab actions for ${menu.id}`}
          style={{ left: Math.min(menu.x, window.innerWidth - 208), top: menu.y }}
        >
          <button type="button" role="menuitem" disabled={opened.length < 2} onClick={() => act(() => onClose(menu.id))}>
            Close
          </button>
          <button type="button" role="menuitem" disabled={opened.length < 2} onClick={() => act(() => onCloseOthers(menu.id))}>
            Close Other Tabs
          </button>
          <button type="button" role="menuitem" disabled={menuIndex === opened.length - 1} onClick={() => act(() => onCloseToRight(menu.id))}>
            Close Tabs to the Right
          </button>
          <button type="button" role="menuitem" onClick={() => act(onCloseAll)}>
            Close All
          </button>
        </div>
      ) : null}
      <div className="umbra-body">
        {opened.includes(file.id) ? (
          <>
            {file.kind === "code" || (file.kind === "md" && !preview) ? <Buffer key={file.id} file={file} text={text} cursor={cursor} onText={onText} onCursor={onCursor} /> : null}
            {file.kind === "md" && preview ? <Markdown text={text} /> : null}
            {file.kind === "hex" ? <Hex /> : null}
            {file.kind === "jfr" ? <Flame /> : null}
          </>
        ) : (
          <div className="umbra-empty-tabs">
            <p>No files open. Open a file from the explorer to continue.</p>
          </div>
        )}
      </div>
    </div>
  );
}

export function Status({ file, cursor, dirty, bottomOn, onTerminal }: { file: FileSpec; cursor: Cursor; dirty: boolean; bottomOn: boolean; onTerminal: () => void }) {
  const crumbs = ["ledger", ...file.path.split("/")];
  const text = file.kind === "code" || file.kind === "md";
  return (
    <div className="umbra-status">
      <span className="umbra-crumbs" aria-label="Location">
        {crumbs.map((crumb, i) => (
          <span key={`${crumb}-${i}`}>
            {i > 0 ? <span className="umbra-sep"> › </span> : null}
            {i === crumbs.length - 1 ? <b>{crumb}</b> : crumb}
          </span>
        ))}
        {dirty ? <i className="umbra-dirty" aria-label="Unsaved changes" /> : null}
      </span>
      <span className="umbra-status-end">
        {text ? (
          <span>
            {cursor.selected ? `${cursor.selected} selected · ` : ""}Ln {cursor.line} · Col {cursor.col}
          </span>
        ) : null}
        {file.lang === "java" ? <span className="jdk">JDK 26</span> : null}
        <span>{file.language}</span>
        <span>UTF-8</span>
        <span>LF</span>
        <button type="button" className={bottomOn ? "is-on" : undefined} onClick={onTerminal}>
          Terminal
        </button>
      </span>
    </div>
  );
}
