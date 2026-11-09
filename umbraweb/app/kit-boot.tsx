"use client";

import { useEffect } from "react";

function load(src: string, module = true) {
  return new Promise<void>((resolve, reject) => {
    const script = document.createElement("script");
    if (module) script.type = "module";
    script.src = src;
    script.onload = () => resolve();
    script.onerror = () => reject(new Error(src));
    document.body.appendChild(script);
  });
}

/** Loads the kit after hydration, so its canvases stay in the document. */
export function KitBoot() {
  useEffect(() => {
    (async () => {
      await load("/assets/backgrounds/backgrounds.js", false);
      await load("/assets/system.js");
      await load("/assets/motion/motion.js");
      await load("/assets/layout/layout.js");
      await load("/assets/diagrams/mount.js");
    })().catch((error) => console.warn("kit", error));
  }, []);
  return null;
}
