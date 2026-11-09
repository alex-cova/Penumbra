"use client";

import { useEffect, useRef, useState } from "react";

const PHRASES = [
  "Code editor for macOS developers",
  "Code editor for Java developers",
  "Code editor for Swift and Markdown",
  "Agent that edits your workspace",
  "Terminal powered by Ghostty",
  "Models on-device with MLX",
];

/** Longest phrase: sets the headline height so rotation never shifts the page. */
const SIZER = PHRASES.reduce((a, b) => (a.length >= b.length ? a : b));

const TYPE_MS = 55;
const DELETE_MS = 28;
const HOLD_MS = 1900;

/**
 * Hero headline that types, holds, deletes and cycles PHRASES.
 * Starts only after the kit's entrance leaves the h1 alone (.is-entered),
 * with a timeout fallback; static under reduced motion.
 */
export function HeroHeadline() {
  const [text, setText] = useState(PHRASES[0]);
  const started = useRef(false);

  useEffect(() => {
    if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) return;
    const hero = document.querySelector(".hero[data-enter]");
    let cancelled = false;
    const timers: number[] = [];
    const later = (fn: () => void, ms: number) => {
      timers.push(
        window.setTimeout(() => {
          if (!cancelled) fn();
        }, ms)
      );
    };

    const run = () => {
      if (started.current || cancelled) return;
      started.current = true;
      let phrase = 0;
      let chars = PHRASES[0].length;
      let deleting = true;
      const step = () => {
        if (cancelled) return;
        const current = PHRASES[phrase];
        if (deleting) {
          chars -= 1;
          setText(current.slice(0, Math.max(chars, 0)));
          if (chars <= 0) {
            phrase = (phrase + 1) % PHRASES.length;
            deleting = false;
            later(step, 350);
          } else {
            later(step, DELETE_MS);
          }
        } else {
          chars += 1;
          setText(current.slice(0, chars));
          if (chars >= current.length) {
            deleting = true;
            later(step, HOLD_MS);
          } else {
            later(step, TYPE_MS);
          }
        }
      };
      later(step, HOLD_MS);
    };

    const entered = () =>
      hero?.classList.contains("is-entered") || hero?.classList.contains("is-still");
    if (!hero || entered()) {
      run();
      return () => {
        cancelled = true;
        timers.forEach((t) => window.clearTimeout(t));
      };
    }
    const mo = new MutationObserver(() => {
      if (entered()) {
        mo.disconnect();
        run();
      }
    });
    mo.observe(hero, { attributes: true, attributeFilter: ["class"] });
    timers.push(
      window.setTimeout(() => {
        mo.disconnect();
        run();
      }, 2600)
    );
    return () => {
      cancelled = true;
      mo.disconnect();
      timers.forEach((t) => window.clearTimeout(t));
    };
  }, []);

  return (
    <h1 id="hero-h">
      <span className="tw-sr">Code editor for macOS developers</span>
      <span className="tw-sizer" aria-hidden="true">
        {SIZER}
      </span>
      <span className="tw-live" aria-hidden="true">
        {text}
        <span className="tw-caret" />
      </span>
    </h1>
  );
}
