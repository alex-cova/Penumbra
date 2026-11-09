"use client";

import { useEffect, useRef, useState } from "react";

const WORD = "Umbra";

/** Footer word with a drifting mesh clipped to the glyphs, revealed letter by letter. */
export function CloseWord() {
  const ref = useRef<HTMLParagraphElement>(null);
  const [armed, setArmed] = useState(false);
  const [inView, setInView] = useState(false);

  useEffect(() => {
    setArmed(true);
    const el = ref.current;
    if (!el) return;
    if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) {
      setInView(true);
      return;
    }
    if (typeof IntersectionObserver === "undefined") {
      setInView(true);
      return;
    }
    const io = new IntersectionObserver(
      (entries) => {
        for (const entry of entries) {
          if (entry.isIntersecting) {
            setInView(true);
            io.disconnect();
          }
        }
      },
      { threshold: 0.35 }
    );
    io.observe(el);
    return () => io.disconnect();
  }, []);

  const classes = ["close__word", "close-word--mesh"];
  if (armed) classes.push("is-armed");
  if (inView) classes.push("is-in");

  return (
    <p ref={ref} className={classes.join(" ")} aria-hidden="true">
      {WORD.split("").map((ch, i) => (
        <span className="cw-mask" key={i} aria-hidden="true">
          <span className="cw-letter" style={{ ["--i" as string]: i }}>
            {ch}
          </span>
        </span>
      ))}
    </p>
  );
}
