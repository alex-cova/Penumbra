"use client";

import { useState } from "react";
import { FLAME, type Frame } from "../data";

type Path = number[];
function at(path: Path): Frame {
  return path.reduce<Frame>((f, i) => f.children![i], FLAME);
}

function Level({ frame, path, root, hover, onHover, onZoom }: { frame: Frame; path: Path; root: Frame; hover: string; onHover: (s: string) => void; onZoom: (p: Path) => void }) {
  return (
    <div className="umbra-flame__col" style={{ flexGrow: frame.value }}>
      <button
        type="button"
        className={`umbra-frame o-${frame.origin}`}
        title={`${frame.name} · ${frame.value}%`}
        onMouseEnter={() => onHover(`${frame.name} · ${Math.round((frame.value / root.value) * 100)}%`)}
        onFocus={() => onHover(`${frame.name} · ${Math.round((frame.value / root.value) * 100)}%`)}
        onClick={() => onZoom(path)}
      >
        <span>{frame.name}</span>
      </button>
      {frame.children?.length ? (
        <div className="umbra-flame__row">
          {frame.children.map((child, i) => (
            <Level key={child.name} frame={child} path={[...path, i]} root={root} hover={hover} onHover={onHover} onZoom={onZoom} />
          ))}
          {frame.children.reduce((s, c) => s + c.value, 0) < frame.value ? (
            <div style={{ flexGrow: frame.value - frame.children.reduce((s, c) => s + c.value, 0) }} />
          ) : null}
        </div>
      ) : null}
    </div>
  );
}

export function Flame() {
  const [zoom, setZoom] = useState<Path>([]);
  const [hover, setHover] = useState("Click a frame to zoom in");
  const root = at(zoom);
  return (
    <div className="umbra-flame">
      <div className="umbra-flame__bar">
        <span>CPU · 100 samples · java.lang.Thread main</span>
        <button type="button" onClick={() => setZoom([])} disabled={zoom.length === 0}>
          Reset zoom
        </button>
      </div>
      <div className="umbra-flame__graph">
        <Level frame={root} path={zoom} root={root} hover={hover} onHover={setHover} onZoom={setZoom} />
      </div>
      <p className="umbra-flame__hint" aria-live="polite">{hover}</p>
      <ul className="umbra-flame__legend" aria-hidden="true">
        <li className="o-java">Java</li>
        <li className="o-native">Native</li>
        <li className="o-jit">JIT</li>
        <li className="o-other">Other</li>
      </ul>
    </div>
  );
}
