"use client";

import { useState } from "react";
import { GRADLE, PROJECT, SWIFTPM } from "./data";
import { Chevron, Cube, Folder, Play, Refresh, Search } from "./icons";

export const BUILD_LABEL = PROJECT === "java" ? "Gradle" : "SwiftPM";

/** The build tool pane on the right: Gradle for a Java project, SwiftPM otherwise. Tasks come from fixtures. */
export function BuildPane() {
  const groups = PROJECT === "java" ? GRADLE : SWIFTPM;
  const [open, setOpen] = useState(groups[0].name);
  return (
    <div className="umbra-agent umbra-card umbra-build">
      <div className="umbra-build__bar">
        <span className="umbra-build__title">
          <Cube /> {BUILD_LABEL}
        </span>
        <span className="sp" />
        <button type="button" aria-label="Reload"><Refresh /></button>
        <button type="button" aria-label="Run"><Play /></button>
        <button type="button" aria-label="Search"><Search /></button>
      </div>
      <div className="umbra-build__body">
        <ul className="umbra-tree">
          <li>
            <span className="umbra-sym">
              <b>ledger</b> <small>{PROJECT === "java" ? "Gradle 9.4.1" : "Swift 6.2"}</small>
            </span>
          </li>
          {groups.map((g) => (
            <li key={g.name}>
              <button type="button" style={{ paddingLeft: 14 }} aria-expanded={open === g.name} onClick={() => setOpen(open === g.name ? "" : g.name)}>
                <Chevron open={open === g.name} />
                <Folder />
                <span className="nm">{g.name}</span>
                <small>{g.count}</small>
              </button>
              {open === g.name ? (
                <ul>
                  {g.tasks?.map((t) => (
                    <li key={t}>
                      <button type="button" style={{ paddingLeft: 44 }}>
                        <span className="nm">{t}</span>
                      </button>
                    </li>
                  ))}
                </ul>
              ) : null}
            </li>
          ))}
          {PROJECT === "java" ? (
            <li>
              <span className="umbra-sym">:app <small>Java 26</small></span>
            </li>
          ) : null}
        </ul>
      </div>
    </div>
  );
}
