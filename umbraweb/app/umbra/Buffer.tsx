"use client";

import { useEffect, useRef, useState } from "react";
import type { FileSpec } from "./data";
import { isMemberStart, memberSeparators, paint } from "./highlight";

const ROW = 20;
const PAD = 8;

export function Painted({ line, lang }: { line: string; lang: FileSpec["lang"] }) {
  if (line === "") return <span>{" "}</span>;
  return (
    <>
      {paint(line, lang).map((part, i) => (
        <span className={part.kind} key={i}>
          {part.text}
        </span>
      ))}
    </>
  );
}

export type Cursor = { line: number; col: number; selected: number };

/**
 * A code buffer you can type in: painted lines underneath, a transparent textarea on top.
 * The textarea owns the caret, selection, IME and mobile keyboard; the painted layer follows its value.
 */
export function Buffer({
  file,
  text,
  cursor,
  onText,
  onCursor,
}: {
  file: FileSpec;
  text: string;
  cursor: Cursor;
  onText: (value: string) => void;
  onCursor: (cursor: Cursor) => void;
}) {
  const scroller = useRef<HTMLDivElement>(null);
  const area = useRef<HTMLTextAreaElement>(null);
  const [focused, setFocused] = useState(false);
  const [scroll, setScroll] = useState({ top: 0, height: 0 });
  const lines = text.split("\n");
  const seps = memberSeparators(lines, file.lang);
  const widest = Math.max(20, ...lines.map((l) => l.length));

  useEffect(() => {
    const el = scroller.current;
    if (!el) return;
    const measure = () => setScroll((s) => ({ top: s.top, height: el.clientHeight }));
    measure();
    const ro = new ResizeObserver(measure);
    ro.observe(el);
    return () => ro.disconnect();
  }, []);

  function readCursor() {
    const el = area.current;
    if (!el) return;
    const before = el.value.slice(0, el.selectionStart);
    const line = before.split("\n").length;
    const col = el.selectionStart - (before.lastIndexOf("\n") + 1) + 1;
    const selected = el.selectionEnd - el.selectionStart;
    onCursor({ line, col, selected });
  }

  function onKeyDown(event: React.KeyboardEvent<HTMLTextAreaElement>) {
    if (event.key === "Tab") {
      event.preventDefault();
      const el = event.currentTarget;
      const next = el.value.slice(0, el.selectionStart) + "    " + el.value.slice(el.selectionEnd);
      const at = el.selectionStart + 4;
      onText(next);
      requestAnimationFrame(() => {
        el.setSelectionRange(at, at);
        readCursor();
      });
    }
    if (event.key === "Escape") event.currentTarget.blur();
  }

  const total = lines.length;
  const mapRow = 4.5;
  const visible = Math.max(1, Math.min(total, Math.round(scroll.height / ROW)));
  const first = Math.min(Math.max(0, total - visible), Math.round(scroll.top / ROW));

  return (
    <div className="umbra-buffer">
      <div
        className="umbra-lines"
        ref={scroller}
        onScroll={(e) => setScroll({ top: e.currentTarget.scrollTop, height: e.currentTarget.clientHeight })}
      >
        <div className="umbra-lines__in" style={{ height: lines.length * ROW + PAD * 2 }}>
          <div className="umbra-curline" style={{ top: PAD + (cursor.line - 1) * ROW }} />
          <div className="umbra-gutters">
            {lines.map((line, i) => (
              <div key={i} className={seps.has(i) ? "umbra-gutter is-sep" : "umbra-gutter"}>
                {isMemberStart(line, file.lang) ? <i className="umbra-mark" aria-hidden="true" /> : null}
                <span className={i + 1 === cursor.line ? "is-on" : undefined}>{i + 1}</span>
              </div>
            ))}
          </div>
          <div className="umbra-codecol" style={{ minWidth: `calc(${widest}ch + 32px)` }}>
            {lines.map((line, i) => (
              <div key={i} className={seps.has(i) ? "umbra-code is-sep" : "umbra-code"}>
                <Painted line={line} lang={file.lang} />
              </div>
            ))}
            {!focused ? <span className="umbra-caret" style={{ top: (cursor.line - 1) * ROW + 3, left: `${cursor.col - 1}ch` }} aria-hidden="true" /> : null}
            <textarea
              ref={area}
              className="umbra-input"
              value={text}
              spellCheck={false}
              autoCapitalize="off"
              autoComplete="off"
              autoCorrect="off"
              aria-label={`Edit ${file.id}`}
              onChange={(e) => {
                onText(e.target.value);
                readCursor();
              }}
              onSelect={readCursor}
              onKeyUp={readCursor}
              onClick={readCursor}
              onKeyDown={onKeyDown}
              onFocus={() => setFocused(true)}
              onBlur={() => setFocused(false)}
            />
          </div>
        </div>
      </div>
      <div className="umbra-map" aria-hidden="true">
        {lines.map((line, i) => (
          <span className="umbra-map__ln" key={i}>
            <Painted line={line} lang={file.lang} />
          </span>
        ))}
        <span className="umbra-map__view" style={{ top: 8 + first * mapRow, height: visible * mapRow }} />
      </div>
    </div>
  );
}
