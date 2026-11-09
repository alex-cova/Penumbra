"use client";

import { useState } from "react";
import { Moon, Refresh, Sun } from "./icons";

const SIZES: Record<string, { px: number; weight: number }> = {
  largeTitle: { px: 34, weight: 400 },
  title: { px: 28, weight: 400 },
  title2: { px: 22, weight: 400 },
  headline: { px: 17, weight: 600 },
  body: { px: 17, weight: 400 },
  subheadline: { px: 15, weight: 400 },
  footnote: { px: 13, weight: 400 },
  caption: { px: 12, weight: 400 },
};

type Rendered = { ok: true; text: string; px: number; weight: number; padded: boolean } | { ok: false; error: string };

/** A tiny reader for the sample view: Text(greeting) with .font, .bold and .padding. Not a Swift parser. */
export function render(source: string): Rendered {
  const name = /let name = "([^"]*)"/.exec(source)?.[1];
  const greeting = /var greeting: String \{\s*"([^"]*)"\s*\}/.exec(source)?.[1];
  const text = /Text\(\s*([^)]*?)\s*\)/.exec(source);
  if (!/struct ContentView\s*:\s*View/.test(source)) return { ok: false, error: "Cannot find 'ContentView' conforming to View" };
  if (!/#Preview/.test(source)) return { ok: false, error: "No #Preview in this file" };
  if (!text) return { ok: false, error: "Body has no Text to show" };
  let value: string;
  if (text[1] === "greeting") {
    if (greeting === undefined) return { ok: false, error: "Cannot find 'greeting' in scope" };
    if (greeting.includes("\\(name)") && name === undefined) return { ok: false, error: "Cannot find 'name' in scope" };
    value = greeting.replace(/\\\(name\)/g, name ?? "");
  } else {
    const literal = /^"([^"]*)"$/.exec(text[1]);
    if (!literal) return { ok: false, error: `Cannot find '${text[1]}' in scope` };
    value = literal[1];
  }
  const font = /\.font\(\.(\w+)\)/.exec(source)?.[1];
  const size = SIZES[font ?? "body"];
  if (!size) return { ok: false, error: `Type 'Font' has no member '${font}'` };
  const bold = /\.bold\(\)/.test(source);
  return { ok: true, text: value, px: size.px, weight: bold ? 700 : size.weight, padded: /\.padding\(/.test(source) };
}

export function PreviewPane({ source }: { source: string }) {
  const [dark, setDark] = useState(false);
  const [zoom, setZoom] = useState(82);
  const [tick, setTick] = useState(1);
  const result = render(source);
  return (
    <div className="umbra-agent umbra-card umbra-preview">
      <div className="umbra-preview__bar">
        <span>Preview {tick}</span>
        <span className="sp" />
        <span className="seg" role="group" aria-label="Appearance">
          <button type="button" aria-pressed={!dark} aria-label="Light" onClick={() => setDark(false)}><Sun /></button>
          <button type="button" aria-pressed={dark} aria-label="Dark" onClick={() => setDark(true)}><Moon /></button>
        </span>
        <button type="button" className="ib" aria-label="Refresh preview" onClick={() => setTick((t) => t + 1)}><Refresh /></button>
      </div>
      <div className="umbra-preview__stage">
        <div className="umbra-phonebox" style={{ transform: `scale(${zoom / 100})` }}>
          <div className={dark ? "screen is-dark" : "screen"}>
            <i className="island" aria-hidden="true" />
            {result.ok ? (
              <div className="content" style={{ padding: result.padded ? 16 : 0 }}>
                <span style={{ fontSize: result.px, fontWeight: result.weight }}>{result.text}</span>
              </div>
            ) : (
              <div className="error" role="alert">
                <b>Preview failed</b>
                <span>{result.error}</span>
              </div>
            )}
          </div>
        </div>
      </div>
      <div className="umbra-preview__zoom">
        <button type="button" aria-label="Zoom out" onClick={() => setZoom((z) => Math.max(40, z - 10))}>−</button>
        <span>{zoom}%</span>
        <button type="button" aria-label="Zoom in" onClick={() => setZoom((z) => Math.min(110, z + 10))}>+</button>
      </div>
    </div>
  );
}
