/** Markdown preview of the buffer: headings, lists, inline code, and a flowchart for the "Flow:" line. */
function inline(text: string) {
  return text.split(/(`[^`]+`|[A-Za-z]+\.[a-zA-Z]+(?:\.[a-zA-Z]+)*|\.\/\w+)/g).map((part, i) =>
    i % 2 === 1 ? <code key={i}>{part.replace(/`/g, "")}</code> : part,
  );
}

const FLOW = [
  { label: "Start", kind: "box" },
  { label: "Greeter.greet", kind: "box" },
  { label: "Cached?", kind: "diamond" },
  { label: "print", kind: "box" },
] as const;

function Flow() {
  return (
    <svg className="umbra-flow" viewBox="0 0 220 250" role="img" aria-label="Flowchart: Start, Greeter.greet, Cached?, print">
      <defs>
        <marker id="umbra-arrow" viewBox="0 0 8 8" refX="7" refY="4" markerWidth="6" markerHeight="6" orient="auto">
          <path d="M0 0 8 4 0 8z" fill="#8a8f96" />
        </marker>
      </defs>
      {[0, 1, 2].map((i) => (
        <line key={i} x1="110" x2="110" y1={[34, 84, 152][i]} y2={[52, 100, 190][i]} stroke="#8a8f96" markerEnd="url(#umbra-arrow)" />
      ))}
      <rect x="70" y="8" width="80" height="26" fill="#1c1d20" stroke="#4a4d52" />
      <text x="110" y="25" textAnchor="middle">Start</text>
      <rect x="55" y="54" width="110" height="26" fill="#1c1d20" stroke="#4a4d52" />
      <text x="110" y="71" textAnchor="middle">Greeter.greet</text>
      <path d="M110 100 160 126 110 152 60 126z" fill="#1c1d20" stroke="#4a4d52" />
      <text x="110" y="130" textAnchor="middle">Cached?</text>
      <rect x="70" y="192" width="80" height="26" fill="#1c1d20" stroke="#4a4d52" />
      <text x="110" y="209" textAnchor="middle">print</text>
    </svg>
  );
}

export function Markdown({ text }: { text: string }) {
  const out: React.ReactNode[] = [];
  let list: string[] = [];
  const flush = () => {
    if (list.length) out.push(<ul key={`l${out.length}`}>{list.map((item, i) => <li key={i}>{inline(item)}</li>)}</ul>);
    list = [];
  };
  text.split("\n").forEach((line, i) => {
    if (line.startsWith("- ")) return void list.push(line.slice(2));
    flush();
    if (line.startsWith("## ")) out.push(<h2 key={i}>{line.slice(3)}</h2>);
    else if (line.startsWith("# ")) out.push(<h1 key={i}>{line.slice(2)}</h1>);
    else if (line.startsWith("Flow:")) out.push(<Flow key={i} />);
    else if (line.trim()) out.push(<p key={i}>{inline(line)}</p>);
  });
  flush();
  return <div className="umbra-md">{out}</div>;
}
void FLOW;
