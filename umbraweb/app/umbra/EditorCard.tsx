"use client";

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
  onText: (v: string) => void;
  onCursor: (c: Cursor) => void;
}) {
  return (
    <div className="umbra-editor umbra-card">
      <div className="umbra-tabs" role="tablist" aria-label="Open files">
        {opened.map((id) => {
          const item = fileById(id);
          const on = id === file.id;
          return (
            <span key={id} className={on ? "umbra-tab is-on" : "umbra-tab"}>
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
      <div className="umbra-body">
        {file.kind === "code" || (file.kind === "md" && !preview) ? <Buffer key={file.id} file={file} text={text} cursor={cursor} onText={onText} onCursor={onCursor} /> : null}
        {file.kind === "md" && preview ? <Markdown text={text} /> : null}
        {file.kind === "hex" ? <Hex /> : null}
        {file.kind === "jfr" ? <Flame /> : null}
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
