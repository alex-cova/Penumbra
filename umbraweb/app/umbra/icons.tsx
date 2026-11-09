/** Small stroke icons, 16px grid, currentColor. */
import type { ReactNode } from "react";

function I({ children, size = 16, className }: { children: ReactNode; size?: number; className?: string }) {
  return (
    <svg viewBox="0 0 16 16" width={size} height={size} className={className} fill="none" stroke="currentColor" strokeWidth="1.1" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      {children}
    </svg>
  );
}

export const PaneLeft = () => (
  <I>
    <rect x="1.5" y="2.5" width="13" height="11" rx="2.5" />
    <path d="M6 2.5v11" />
  </I>
);
export const PaneBottom = () => (
  <I>
    <rect x="1.5" y="2.5" width="13" height="11" rx="2.5" />
    <path d="M1.5 10h13" />
  </I>
);
export const PaneRight = () => (
  <I>
    <rect x="1.5" y="2.5" width="13" height="11" rx="2.5" />
    <path d="M10 2.5v11" />
  </I>
);
export const Branch = () => (
  <I size={12}>
    <circle cx="4" cy="3.5" r="1.4" />
    <circle cx="4" cy="12.5" r="1.4" />
    <circle cx="12" cy="5.5" r="1.4" />
    <path d="M4 5v6M12 7c0 3-8 1.5-8 4" />
  </I>
);
export const Hammer = () => (
  <I>
    <path d="m9.5 3.5 3 3M3 13l5.5-5.5M7 4l3-2 4 4-2 3z" />
  </I>
);
export const Bolt = () => (
  <I>
    <path d="M9 1.5 3.5 9H7l-1 5.5L11.5 7H8z" />
  </I>
);
export const Search = () => (
  <I>
    <circle cx="7" cy="7" r="4" />
    <path d="m10.2 10.2 3.8 3.8" />
  </I>
);
export const Bell = () => (
  <I>
    <path d="M8 2a4 4 0 0 1 4 4c0 2.6 1 3.6 1 3.6H3S4 7.6 4 6a4 4 0 0 1 4-4zM6.5 12.5a1.5 1.5 0 0 0 3 0" />
  </I>
);
export const Brain = () => (
  <I>
    <path d="M6 3a2.2 2.2 0 0 0-2.5 2.6A2.3 2.3 0 0 0 3 9.5 2.4 2.4 0 0 0 5.5 13H8V3.2A2 2 0 0 0 6 3zM10 3a2.2 2.2 0 0 1 2.5 2.6A2.3 2.3 0 0 1 13 9.5 2.4 2.4 0 0 1 10.5 13H8" />
  </I>
);
export const Gear = () => (
  <I>
    <circle cx="8" cy="8" r="2" />
    <path d="M8 1.5v2M8 12.5v2M1.5 8h2M12.5 8h2M3.4 3.4l1.4 1.4M11.2 11.2l1.4 1.4M3.4 12.6l1.4-1.4M11.2 4.8l1.4-1.4" />
  </I>
);
export const Eye = () => (
  <I>
    <path d="M1.5 8S4 3.5 8 3.5 14.5 8 14.5 8 12 12.5 8 12.5 1.5 8 1.5 8z" />
    <circle cx="8" cy="8" r="2" />
  </I>
);
export const Folder = () => (
  <I size={14}>
    <path d="M1.5 4.5a1 1 0 0 1 1-1h3.2l1.3 1.5h6.5a1 1 0 0 1 1 1v6a1 1 0 0 1-1 1h-11a1 1 0 0 1-1-1z" />
  </I>
);
export const Chevron = ({ open }: { open?: boolean }) => (
  <I size={10} className={open ? "umbra-chev is-open" : "umbra-chev"}>
    <path d="m6 3.5 4.5 4.5L6 12.5" />
  </I>
);
export const Plus = () => (
  <I size={14}>
    <path d="M8 3v10M3 8h10" />
  </I>
);
export const Close = () => (
  <I size={12}>
    <path d="m4 4 8 8M12 4l-8 8" />
  </I>
);
export const Play = () => (
  <I size={14}>
    <path d="m5 3.5 7 4.5-7 4.5z" />
  </I>
);
export const Refresh = () => (
  <I size={14}>
    <path d="M13 8a5 5 0 1 1-1.6-3.7M13 2.5v3h-3" />
  </I>
);
export const Check = () => (
  <I size={14}>
    <path d="m3.5 8.5 3 3 6-7" />
  </I>
);
export const Undo = () => (
  <I size={14}>
    <path d="M3 6h6.5a3.5 3.5 0 0 1 0 7H6M3 6l3-3M3 6l3 3" />
  </I>
);

/** File icons: the Java cup, a page, a doc, a hex grid, a flame. */
export function FileIcon({ kind, lang }: { kind: string; lang: string }) {
  if (kind === "hex")
    return (
      <I size={13}>
        <rect x="2" y="2" width="12" height="12" rx="2" />
        <path d="M5 6h2M9 6h2M5 10h2M9 10h2" />
      </I>
    );
  if (kind === "jfr")
    return (
      <I size={13}>
        <path d="M8 1.8c.4 2.2 3.6 3.6 3.6 7A3.6 3.6 0 0 1 8 12.4a3.6 3.6 0 0 1-3.6-3.6c0-1.5.7-2.4 1.5-3.2.1 1 .6 1.6 1.2 1.7C6.8 5 7.2 3.2 8 1.8z" />
      </I>
    );
  if (kind === "md")
    return (
      <I size={13}>
        <rect x="2.5" y="2" width="11" height="12" rx="1.5" />
        <path d="M5 6h6M5 9h6M5 11.5h3" />
      </I>
    );
  if (lang === "java")
    return (
      <I size={13}>
        <path d="M3.5 9.5c0-1.2 2-2 4.5-2s4.5.8 4.5 2-2 2-4.5 2-4.5-.8-4.5-2zM3.5 9.5V11c0 1.2 2 2 4.5 2s4.5-.8 4.5-2V9.5M5.5 6c0-1.5 1-1.7 1-3M8.5 6c0-1.5 1-1.7 1-3" />
      </I>
    );
  return (
    <I size={13}>
      <path d="M3.5 1.5h5l4 4v9h-9z" />
      <path d="M8.5 1.5v4h4" />
    </I>
  );
}

export const List = () => (
  <I>
    <path d="M3 4h10M3 8h10M3 12h6" />
  </I>
);
export const Cube = () => (
  <I>
    <path d="m8 1.8 5.5 3v6.4L8 14.2l-5.5-3V4.8zM2.5 4.8 8 8l5.5-3.2M8 8v6.2" />
  </I>
);
export const Dot = () => (
  <svg viewBox="0 0 16 16" width="16" height="16" aria-hidden="true">
    <circle cx="8" cy="8" r="3.4" fill="#ef5b5b" />
  </svg>
);
export const Stop = () => (
  <svg viewBox="0 0 16 16" width="16" height="16" aria-hidden="true">
    <rect x="3.5" y="3.5" width="9" height="9" rx="2" fill="currentColor" />
  </svg>
);
export const Sun = () => (
  <I>
    <circle cx="8" cy="8" r="2.8" />
    <path d="M8 1.5v1.6M8 12.9v1.6M1.5 8h1.6M12.9 8h1.6M3.4 3.4l1.1 1.1M11.5 11.5l1.1 1.1M3.4 12.6l1.1-1.1M11.5 4.5l1.1-1.1" />
  </I>
);
export const Moon = () => (
  <I>
    <path d="M12.8 9.6A5.4 5.4 0 0 1 6.4 3.2a5.4 5.4 0 1 0 6.4 6.4z" />
  </I>
);
