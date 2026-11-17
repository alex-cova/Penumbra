"use client";

import { useEffect, useRef, useState } from "react";
import { InstallCmd } from "./install-cmd";

const releases = "https://github.com/alex-cova/Penumbra/releases";

type BackendId = "muse" | "openai" | "ollama" | "mlx" | "apple";

const BACKENDS: { id: BackendId; label: string; status: "Needs key" | "Connected" | "On-device"; hint: string }[] = [
  { id: "muse", label: "Meta Muse", status: "Needs key", hint: "API key in the Keychain" },
  { id: "openai", label: "OpenAI-compatible", status: "Needs key", hint: "Base URL + key in the Keychain" },
  { id: "ollama", label: "Ollama", status: "Connected", hint: "Local Ollama server" },
  { id: "mlx", label: "MLX", status: "On-device", hint: "On-device coding agent with MLX" },
  { id: "apple", label: "Apple Intelligence", status: "On-device", hint: "On-device when available" },
];

/* Deterministic scripted demo: callback-based Swift becomes async/await. */
const STREAM_TOKENS = [
  "Reading ContentView.swift",
  "callers pass a completion handler",
  "rewriting loadUser with async/await",
  "checking call sites in the workspace",
  "verifying the diff",
];

const BEFORE_LINES = [
  "func loadUser(id: Int, completion: @escaping (User) -> Void) {",
  "    api.fetchUser(id) { user in",
  "        completion(user)",
  "    }",
  "}",
];

const AFTER_LINES = ["func loadUser(id: Int) async -> User {", "    await api.user(id: id)", "}"];

type DemoPhase = "idle" | "streaming" | "done";

export function AcpSection() {
  const [backend, setBackend] = useState<BackendId>("ollama");
  const [phase, setPhase] = useState<DemoPhase>("idle");
  const [shown, setShown] = useState(0);
  const timers = useRef<number[]>([]);
  useEffect(() => () => timers.current.forEach((t) => window.clearTimeout(t)), []);

  const active = BACKENDS.find((b) => b.id === backend) ?? BACKENDS[2];
  const reduced =
    typeof window !== "undefined" &&
    typeof window.matchMedia === "function" &&
    window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  function run() {
    timers.current.forEach((t) => window.clearTimeout(t));
    timers.current = [];
    if (reduced) {
      setShown(STREAM_TOKENS.length);
      setPhase("done");
      return;
    }
    setPhase("streaming");
    setShown(0);
    STREAM_TOKENS.forEach((_, i) => {
      timers.current.push(
        window.setTimeout(() => {
          setShown(i + 1);
          if (i + 1 === STREAM_TOKENS.length) setPhase("done");
        }, 450 * (i + 1)),
      );
    });
  }

  function revert() {
    timers.current.forEach((t) => window.clearTimeout(t));
    timers.current = [];
    setPhase("idle");
    setShown(0);
  }

  return (
    <section className="section" id="acp" aria-labelledby="acp-h">
      <div className="wrap">
        <p className="acp__flag">Planned direction — not shipped yet</p>
        <div className="section-head">
          <h2 id="acp-h">Your AI. Your subscription. Your editor.</h2>
          <p>
            Umbra&apos;s built-in coding agent works with your models today — Meta Muse, OpenAI-compatible APIs,
            Ollama, and on-device models through MLX or Apple Intelligence. ACP support is a planned direction:
            connect the agent you already pay for, in the editor you already use.
          </p>
        </div>

        <ul className="acp__chips" aria-label="Model backends that work today">
          {BACKENDS.map((b) => (
            <li key={b.id} className="acp__chip">
              {b.label}
            </li>
          ))}
          <li className="acp__chip acp__chip--planned" aria-label="Future ACP provider slots">
            Coming with ACP support
          </li>
        </ul>

        <div className="acp__grid">
          <article className="card">
            <h3>Bring your account</h3>
            <p>Use your existing AI subscription instead of paying per seat twice.</p>
            <p className="acp__caveat">*Requires provider ACP availability and your own active subscription.</p>
          </article>
          <article className="card">
            <h3>Keep your workflow</h3>
            <p>Agent edits land as diffs in Umbra&apos;s buffer, diff, and history panes — review and revert like today.</p>
            <p className="acp__caveat">*Requires ACP file-edit capability from the connected agent.</p>
          </article>
          <article className="card">
            <h3>Choose your agent</h3>
            <p>Switch backends per task: cloud for heavy refactors, on-device MLX or Apple Intelligence for offline work.</p>
            <p className="acp__caveat">*Model availability depends on macOS version and hardware.</p>
          </article>
        </div>

        <p className="acp__explainer">
          ACP (Agent Client Protocol) is an open protocol that lets any compatible AI agent drive your editor — learn
          more at{" "}
          <a className="link" href="https://agentclientprotocol.com/">
            agentclientprotocol.com
          </a>
          .
        </p>
        <details className="acp__details">
          <summary>How an ACP session would work</summary>
          <p>
            The client and agent talk over a JSON-RPC-style session. The editor owns files, diffs, and permissions;
            the agent proposes edits that stream back into the open tab. Keys stay in the Keychain. Each session
            starts fresh in the current workspace — Umbra does not sync history across agents.
          </p>
        </details>

        <div className="acp__demo">
          <div className="acp__controls">
            <label className="acp__label" htmlFor="acp-backend">
              Agent backend
            </label>
            <select
              id="acp-backend"
              className="acp__select"
              value={backend}
              onChange={(e) => setBackend(e.target.value as BackendId)}
            >
              {BACKENDS.map((b) => (
                <option key={b.id} value={b.id}>
                  {b.label}
                </option>
              ))}
              <option disabled value="__planned">
                ACP agent — planned
              </option>
            </select>
            <p className="acp__status" aria-live="polite">
              <span className={`acp__pill acp__pill--${active.status === "Needs key" ? "key" : active.status === "Connected" ? "live" : "device"}`}>
                {active.status}
              </span>{" "}
              {active.hint}
            </p>
            <div className="btn-row">
              <button className="btn btn--primary" type="button" onClick={run} disabled={phase === "streaming"}>
                {phase === "streaming" ? "Running demo…" : "Run demo"}
              </button>
              {phase === "done" ? (
                <button className="btn btn--secondary" type="button" onClick={revert}>
                  Revert run
                </button>
              ) : null}
            </div>
          </div>
          <div className="acp__screen" aria-live="polite" aria-label="Demo: Swift concurrency refactor">
            <p className="acp__screen-head">
              <span>ContentView.swift</span>
              <span>{phase === "done" ? "async/await" : "callback"}</span>
            </p>
            <ul className="acp__stream">
              {STREAM_TOKENS.slice(0, shown).map((t) => (
                <li key={t}>{t}</li>
              ))}
              {phase === "idle" ? <li className="acp__idle">Pick a backend and run the demo.</li> : null}
            </ul>
            <pre className="acp__diff">
              <code>
                {(phase === "done" ? AFTER_LINES : BEFORE_LINES).map((line) => (
                  <span key={line} className={phase === "done" ? "is-add" : "is-del"}>
                    {line}
                  </span>
                ))}
              </code>
            </pre>
          </div>
        </div>
        <p className="acp__caption">Different agents. One workspace.</p>

        <div className="acp__cta">
          <div className="btn-row">
            <a className="btn btn--primary" href={releases}>
              Download Umbra
            </a>
          </div>
          <InstallCmd />
          <p className="acp__build">Prefer source? Run ./run.sh (needs macOS 26 and Xcode 26).</p>
        </div>
      </div>
    </section>
  );
}
