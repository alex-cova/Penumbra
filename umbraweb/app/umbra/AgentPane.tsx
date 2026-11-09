"use client";

import { useEffect, useRef, useState } from "react";
import { AGENT_CANNED, AGENT_DONE, AGENT_PROMPT, AGENT_TEXT } from "./data";
import { Undo } from "./icons";

type Phase = "idle" | "thinking" | "editing" | "done" | "reverted";

export function AgentPane({ onEdit, onRevert }: { onEdit: () => void; onRevert: () => void }) {
  const [phase, setPhase] = useState<Phase>("idle");
  const [prompt, setPrompt] = useState("");
  const [canned, setCanned] = useState<string | null>(null);
  const [asked, setAsked] = useState("");
  const timers = useRef<number[]>([]);
  useEffect(() => () => timers.current.forEach((t) => window.clearTimeout(t)), []);

  function later(ms: number, fn: () => void) {
    timers.current.push(window.setTimeout(fn, ms));
  }
  function send(text: string) {
    const value = text.trim();
    if (!value || phase === "thinking" || phase === "editing") return;
    setAsked(value);
    setPrompt("");
    if (value.toLowerCase() === AGENT_PROMPT.toLowerCase()) {
      setCanned(null);
      setPhase("thinking");
      later(900, () => {
        setPhase("editing");
        onEdit();
      });
      later(1800, () => setPhase("done"));
    } else {
      setCanned(AGENT_CANNED);
      setPhase("idle");
    }
  }
  const ran = phase === "editing" || phase === "done" || phase === "reverted";

  return (
    <div className="umbra-agent umbra-card">
      <div className="umbra-agent__bar">
        <b>Agent</b>
        <span>{ran ? "106.1K tokens" : "0 tokens"}</span>
      </div>
      <div className="umbra-agent__log" aria-live="polite">
        {asked ? <p className="you">{asked}</p> : <p className="hint">Ask about this project, or try the suggestion below.</p>}
        {canned ? <p>{canned}</p> : null}
        {phase !== "idle" ? (
          <>
            {AGENT_TEXT.map((t) => (
              <p key={t}>{t}</p>
            ))}
            <p className="tool"><span>› edit_file ledger/src/main/java/…/Greeter.java</span><i>{ran ? "✓" : "…"}</i></p>
          </>
        ) : null}
        {phase === "done" || phase === "reverted" ? (
          <>
            <p className="tool"><span>› diagnostics ledger/src/main/java/…/Greeter.java</span><i>✓</i></p>
            <p>{phase === "done" ? AGENT_DONE : "Run reverted. The buffer is back to what you had."}</p>
            {phase === "done" ? (
              <div className="umbra-changed">
                <span>1 file changed</span>
                <button
                  type="button"
                  onClick={() => {
                    onRevert();
                    setPhase("reverted");
                  }}
                >
                  <Undo /> Revert run
                </button>
              </div>
            ) : null}
          </>
        ) : null}
      </div>
      <form
        className="umbra-agent__ask"
        onSubmit={(e) => {
          e.preventDefault();
          send(prompt);
        }}
      >
        {phase === "idle" && !asked ? (
          <button type="button" className="chip" onClick={() => send(AGENT_PROMPT)}>
            {AGENT_PROMPT}
          </button>
        ) : null}
        <input value={prompt} onChange={(e) => setPrompt(e.target.value)} placeholder="Ask about this project…" aria-label="Ask the agent" />
      </form>
    </div>
  );
}
