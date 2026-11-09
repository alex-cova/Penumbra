"use client";

import { useState } from "react";

const command = "brew install --cask alex-cova/umbra/umbra";

export function InstallCmd() {
  const [copied, setCopied] = useState(false);

  async function copy() {
    try {
      await navigator.clipboard.writeText(command);
    } catch {
      return;
    }
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
  }

  return (
    <div className="hero__install">
      <p className="hero__install-caption">Or install with Homebrew</p>
      <div className="hero__install-row">
        <input className="hero__install-field" type="text" readOnly value={command} aria-label="Homebrew install command" onFocus={(event) => event.target.select()} />
        <button
          className="hero__install-copy"
          type="button"
          onClick={copy}
          aria-label="Copy install command"
          title={copied ? "Copied" : "Copy install command"}
        >
          {copied ? (
            <svg width="13" height="13" viewBox="0 0 13 13" aria-hidden="true">
              <path d="m2.5 6.8 2.4 2.4 5.6-6" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" />
            </svg>
          ) : (
            <svg width="13" height="13" viewBox="0 0 13 13" aria-hidden="true">
              <rect x="4" y="4" width="7" height="7" rx="1.5" fill="none" stroke="currentColor" strokeWidth="1.3" />
              <path d="M9 4V2.5A1.5 1.5 0 0 0 7.5 1H3.5A1.5 1.5 0 0 0 2 2.5v4A1.5 1.5 0 0 0 3.5 8H4" fill="none" stroke="currentColor" strokeWidth="1.3" />
            </svg>
          )}
        </button>
      </div>
    </div>
  );
}
