import { Bell, Bolt, Branch, Brain, Eye, Gear, Hammer, PaneBottom, PaneLeft, PaneRight, Search, Stop } from "./icons";

export function TitleBar({
  side,
  bottom,
  right,
  onSide,
  onBottom,
  onRight,
  preview,
  onPreview,
  mode,
  swift,
  onAgent,
  onSwiftPreview,
}: {
  side: boolean;
  bottom: boolean;
  right: boolean;
  onSide: () => void;
  onBottom: () => void;
  onRight: () => void;
  preview: boolean | null;
  onPreview: () => void;
  mode: "build" | "agent" | "preview";
  swift: boolean;
  onAgent: () => void;
  onSwiftPreview: () => void;
}) {
  const toggle = (on: boolean, label: string, fn: () => void, icon: React.ReactNode, cls = "umbra-ib") => (
    <button type="button" className={cls} aria-pressed={on} aria-label={label} title={label} onClick={fn}>
      {icon}
    </button>
  );
  return (
    <div className="umbra-chrome">
      <span className="umbra-lights" aria-hidden="true">
        <i />
        <i />
        <i />
      </span>
      <span className="umbra-panes">
        {toggle(side, side ? "Hide sidebar" : "Show sidebar", onSide, <PaneLeft />)}
        {toggle(bottom, bottom ? "Hide panel" : "Show panel", onBottom, <PaneBottom />)}
        {toggle(right, right ? "Hide right pane" : "Show right pane", onRight, <PaneRight />)}
      </span>
      <span className="umbra-title">
        ledger <Branch /> <span className="umbra-branch">main</span>
      </span>
      <span className="umbra-tools">
        {preview !== null ? toggle(preview, preview ? "Show source" : "Show preview", onPreview, <Eye />) : null}
        <span className="umbra-dec"><Hammer /></span>
        <span className="umbra-dec"><Bolt /></span>
        <span className="umbra-dec"><Search /></span>
        <span className="umbra-dec"><Bell /></span>
        {swift ? toggle(right && mode === "preview", right && mode === "preview" ? "Hide SwiftUI preview" : "Show SwiftUI preview", onSwiftPreview, <Stop />) : null}
        {toggle(right && mode === "agent", right && mode === "agent" ? "Hide agent" : "Show agent", onAgent, <Brain />)}
        <span className="umbra-dec"><Gear /></span>
      </span>
    </div>
  );
}
