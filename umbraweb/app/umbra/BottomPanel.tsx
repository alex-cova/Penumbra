"use client";

import { useEffect, useRef, useState } from "react";
import { terminal } from "./data";

export type BottomTab = "terminal" | "problems" | "history";
const TABS: [BottomTab, string][] = [
  ["terminal", "ledger"],
  ["problems", "Problems"],
  ["history", "History"],
];
const PROMPT = "alex@mac ledger %";

function Terminal() {
  const [lines, setLines] = useState<string[]>([]);
  const [value, setValue] = useState("");
  const end = useRef<HTMLDivElement>(null);
  useEffect(() => {
    const el = end.current?.parentElement;
    if (el) el.scrollTop = el.scrollHeight;
  }, [lines]);
  function run() {
    const out = terminal(value);
    if (out === "clear") setLines([]);
    else setLines((l) => [...l, `${PROMPT} ${value}`, ...out]);
    setValue("");
  }
  return (
    <div className="umbra-term" onClick={(e) => e.currentTarget.querySelector("input")?.focus()}>
      <div aria-live="polite">
        <p>Last login: Sun Nov 8 on ttys001. Type help.</p>
        {lines.map((l, i) => (
          <p key={i}>{l}</p>
        ))}
      </div>
      <label>
        <span>{PROMPT}</span>
        <input value={value} onChange={(e) => setValue(e.target.value)} onKeyDown={(e) => e.key === "Enter" && run()} spellCheck={false} autoCapitalize="off" autoComplete="off" aria-label="Terminal input" />
      </label>
      <div ref={end} />
    </div>
  );
}

export function BottomPanel({ tab, onTab, history }: { tab: BottomTab; onTab: (t: BottomTab) => void; history: React.ReactNode }) {
  return (
    <div className="umbra-bottom umbra-card">
      <div className="umbra-ptabs" role="tablist" aria-label="Panel">
        {TABS.map(([id, label]) => (
          <button key={id} type="button" role="tab" aria-selected={tab === id} onClick={() => onTab(id)}>
            {label}
          </button>
        ))}
      </div>
      <div className="umbra-pbody">
        {tab === "terminal" ? <Terminal /> : null}
        {tab === "problems" ? <p className="umbra-empty">No problems in ledger</p> : null}
        {tab === "history" ? history : null}
      </div>
    </div>
  );
}
