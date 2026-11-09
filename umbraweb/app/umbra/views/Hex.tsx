"use client";

import { useState } from "react";
import { HEX_BYTES } from "../data";

const PER_ROW = 16;
const hex = (n: number, w = 2) => n.toString(16).toUpperCase().padStart(w, "0");
const printable = (b: number) => (b >= 0x20 && b < 0x7f ? String.fromCharCode(b) : "·");
const tone = (b: number) => (b === 0 ? "z" : b >= 0x20 && b < 0x7f ? "t" : b === 0xff ? "f" : "o");

export function Hex() {
  const [sel, setSel] = useState<[number, number]>([0, 3]);
  const [lo, hi] = sel[0] <= sel[1] ? sel : [sel[1], sel[0]];
  const bytes = HEX_BYTES.slice(lo, hi + 1);
  const u8 = bytes[0];
  const u16 = bytes.length >= 2 ? bytes[0] | (bytes[1] << 8) : null;
  const u32 = bytes.length >= 4 ? (bytes[0] | (bytes[1] << 8) | (bytes[2] << 16) | (bytes[3] << 24)) >>> 0 : null;
  const rows = Math.ceil(HEX_BYTES.length / PER_ROW);

  return (
    <div className="umbra-hex">
      <div className="umbra-hex__grid" role="grid" aria-label="Bytes of ledger.bin">
        <div className="umbra-hex__head">
          <span>Offset</span>
          <span className="bytes">
            {Array.from({ length: PER_ROW }, (_, i) => (
              <b key={i}>{hex(i)}</b>
            ))}
          </span>
          <span>Text</span>
        </div>
        {Array.from({ length: rows }, (_, row) => {
          const slice = HEX_BYTES.slice(row * PER_ROW, row * PER_ROW + PER_ROW);
          return (
            <div className="umbra-hex__row" key={row} role="row">
              <span className="off">{hex(row * PER_ROW, 8)}</span>
              <span className="bytes">
                {slice.map((b, i) => {
                  const at = row * PER_ROW + i;
                  return (
                    <button
                      type="button"
                      key={i}
                      className={`${tone(b)}${at >= lo && at <= hi ? " is-sel" : ""}`}
                      onClick={(e) => setSel(e.shiftKey ? [sel[0], at] : [at, at])}
                      aria-label={`Byte ${at}: ${hex(b)}`}
                    >
                      {hex(b)}
                    </button>
                  );
                })}
              </span>
              <span className="txt">
                {slice.map((b, i) => (
                  <i key={i} className={row * PER_ROW + i >= lo && row * PER_ROW + i <= hi ? "is-sel" : undefined}>
                    {printable(b)}
                  </i>
                ))}
              </span>
            </div>
          );
        })}
      </div>
      <dl className="umbra-hex__inspect" aria-label="Inspector">
        <div><dt>Offset</dt><dd>{lo}{hi > lo ? `–${hi}` : ""}</dd></div>
        <div><dt>UInt8</dt><dd>{u8}</dd></div>
        <div><dt>UInt16 LE</dt><dd>{u16 ?? "—"}</dd></div>
        <div><dt>UInt32 LE</dt><dd>{u32 ?? "—"}</dd></div>
        <div><dt>ASCII</dt><dd>{bytes.slice(0, 8).map(printable).join("")}</dd></div>
      </dl>
    </div>
  );
}
