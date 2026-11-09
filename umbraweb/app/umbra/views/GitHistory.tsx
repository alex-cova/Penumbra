"use client";

import { useMemo, useState } from "react";
import { COMMITS, type Commit } from "../data";

const ROW = 46;
const LANE = 14;
const LEFT = 10;
const COLORS = ["#6bc38b", "#e0b84b", "#6ea0ff", "#e394dc"];

type Row = {
  commit: Commit;
  dot: number;
  /** lanes with a line entering the row from above (lane index -> lane it ends in: the dot lane for merges) */
  top: { from: number; to: number }[];
  /** lanes leaving the row downwards (from the dot lane or straight through) */
  bottom: { from: number; to: number }[];
  width: number;
};

/** Standard commit-graph lane assignment, newest first. */
function layout(commits: Commit[]): Row[] {
  let lanes: (string | null)[] = [];
  const rows: Row[] = [];
  for (const commit of commits) {
    let dot = lanes.indexOf(commit.id);
    if (dot < 0) {
      dot = lanes.indexOf(null);
      if (dot < 0) dot = lanes.length;
      lanes[dot] = commit.id;
    }
    const top: Row["top"] = [];
    lanes.forEach((id, i) => {
      if (id === null) return;
      top.push({ from: i, to: id === commit.id ? dot : i });
    });
    const next = [...lanes];
    commit.parents.forEach((parent, index) => {
      if (index === 0) {
        next[dot] = parent;
        return;
      }
      let at = next.indexOf(parent);
      if (at < 0) {
        at = next.indexOf(null);
        if (at < 0) at = next.length;
        next[at] = parent;
      }
    });
    if (commit.parents.length === 0) next[dot] = null;
    lanes.forEach((id, i) => {
      if (id === commit.id && i !== dot) next[i] = null;
    });
    const bottom: Row["bottom"] = [];
    next.forEach((id, i) => {
      if (id === null) return;
      if (i === dot) return void bottom.push({ from: dot, to: i });
      bottom.push({ from: lanes[i] === id ? i : dot, to: i });
    });
    const width = Math.max(lanes.length, next.length, dot + 1);
    rows.push({ commit, dot, top, bottom, width });
    while (next.length && next[next.length - 1] === null) next.pop();
    lanes = next;
  }
  return rows;
}

const x = (lane: number) => LEFT + lane * LANE;
const curve = (x1: number, y1: number, x2: number, y2: number) =>
  x1 === x2 ? `M${x1} ${y1}V${y2}` : `M${x1} ${y1}C${x1} ${(y1 + y2) / 2} ${x2} ${(y1 + y2) / 2} ${x2} ${y2}`;

function Graph({ row, maxLanes }: { row: Row; maxLanes: number }) {
  const mid = ROW / 2;
  return (
    <svg className="umbra-graph" width={LEFT * 2 + (maxLanes - 1) * LANE} height={ROW} aria-hidden="true">
      {row.top.map((l, i) => (
        <path key={`t${i}`} d={curve(x(l.from), 0, x(l.to), mid)} stroke={COLORS[l.from % COLORS.length]} />
      ))}
      {row.bottom.map((l, i) => (
        <path key={`b${i}`} d={curve(x(l.from), mid, x(l.to), ROW)} stroke={COLORS[l.to % COLORS.length]} />
      ))}
      <circle cx={x(row.dot)} cy={mid} r="4.2" fill={COLORS[row.dot % COLORS.length]} stroke="#17181a" strokeWidth="1.5" />
    </svg>
  );
}

export function GitHistory({ added }: { added: { id: string; msg: string; files: string[] }[] }) {
  const all: Commit[] = useMemo(() => {
    const mine = added.map((c, i) => ({
      id: c.id,
      msg: c.msg,
      who: "you",
      when: "just now",
      parents: [added[i + 1]?.id ?? COMMITS[0].id],
      files: c.files.map((name) => ({ name, add: 1, del: 0 })),
      diff: ["@@ staged changes @@", ...c.files.map((f) => `+ ${f}`)],
    }));
    return [...mine, ...COMMITS];
  }, [added]);
  const rows = useMemo(() => layout(all), [all]);
  const maxLanes = Math.max(2, ...rows.map((r) => r.width));
  const [sel, setSel] = useState(all[0].id);
  const commit = all.find((c) => c.id === sel) ?? all[0];
  return (
    <div className="umbra-git">
      <ul className="umbra-git__list" aria-label="Commits">
        {rows.map((row) => (
          <li key={row.commit.id}>
            <button type="button" aria-current={row.commit.id === sel ? "true" : undefined} onClick={() => setSel(row.commit.id)}>
              <Graph row={row} maxLanes={maxLanes} />
              <span>
                <b>{row.commit.msg}</b>
                <small>
                  {row.commit.id} · {row.commit.who} · {row.commit.when}
                </small>
              </span>
            </button>
          </li>
        ))}
      </ul>
      <div className="umbra-git__diff">
        <p className="head">
          <b>commit {commit.id}</b>
        </p>
        {commit.files.map((f) => (
          <p key={f.name} className="file">
            <span className="m">M</span> {f.name} <small>+{f.add} −{f.del}</small>
          </p>
        ))}
        <pre>
          {commit.diff.map((line, i) => (
            <span key={i} className={line.startsWith("+") ? "add" : line.startsWith("-") ? "del" : line.startsWith("@@") ? "hunk" : undefined}>
              {line + "\n"}
            </span>
          ))}
        </pre>
      </div>
    </div>
  );
}
