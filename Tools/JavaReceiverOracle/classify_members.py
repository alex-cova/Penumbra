#!/usr/bin/env python3
"""Independent member-set classification of the receiver audit's non-exact sites.

The receiver audit (JavaReceiverTypeAuditHarness) buckets a site by how javac and the engine *write* the
receiver type. This script asks a different question of the same sites: does the engine offer the members
javac makes accessible through that receiver? It reads `JAVA_AUDIT_MEMBERS` output (one JSON object per
compared, non-exact site, with the engine's member labels and the receiver's UTF-16 range), runs
ReceiverMemberOracle.java once per file with the project's classpath, sourcepath and annotation processors,
and classifies each site:

  equivalent        engine members == javac members
  engine-missing    javac offers members the engine does not (and the engine offers nothing extra)
  engine-invalid    the engine offers members javac does not (and misses none)
  both              both differences
  ... (only protected clone/finalize)   the difference is Object's protected members alone
  javac-no-type     javac attributed no type at that range
  unmatched         the oracle found no member select at that exact range

It never changes the audit's buckets; it is reported next to them.

  python3 -I classify_members.py <members.jsonl> [--out report.txt]
"""
import collections, json, os, subprocess, sys
from urllib.parse import unquote, urlparse

ORACLE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "ReceiverMemberOracle.java")
MODELS = os.path.expanduser("~/Library/Application Support/com.umbra.editor/gradle-models")


def processor_path(project):
    """Annotation processor jars of the Gradle model whose root directory is named `project`."""
    if not os.path.isdir(MODELS):
        return []
    for entry in sorted(os.listdir(MODELS)):
        try:
            model = json.load(open(os.path.join(MODELS, entry, "model.json")))
        except Exception:
            continue
        roots = [s for s in model["subprojects"] if s["path"] == ":"] or model["subprojects"]
        directory = unquote(urlparse(roots[0]["directory"]).path).rstrip("/")
        if os.path.basename(directory) != project:
            continue
        jars = []
        for sub in model["subprojects"]:
            for ss in sub["sourceSets"]:
                if ss["name"] != "main":
                    continue
                for jar in ss.get("annotationProcessorJars", []):
                    path = unquote(urlparse(jar).path)
                    if os.path.exists(path) and path not in jars:
                        jars.append(path)
        return jars
    return []


def run_oracle(path, sites, project):
    command = ["java", ORACLE]
    if project.get("classpath"):
        command += ["-cp", ":".join(project["classpath"])]
    if project.get("sourcepath"):
        command += ["-sourcepath", ":".join(project["sourcepath"])]
    processors = project.get("processorpath") or []
    if processors:
        command += ["-processorpath", ":".join(processors)]
    command += [path] + sites
    result = subprocess.run(command, capture_output=True, text=True, timeout=600)
    found = {}
    current = None
    for row in result.stdout.splitlines():
        text = row.strip()
        if text.startswith("== line"):
            at = text.rsplit(" @", 1)[1].split(" ", 1)[0] if " @" in text else None
            current = {"at": "@" + at if at else None, "type": None, "members": None}
            if current["at"]:
                found.setdefault(current["at"], current)
        elif current is not None and text.startswith("type:"):
            current["type"] = text[len("type:"):].split("   (kind")[0].strip()
        elif current is not None and text.startswith("static-interface:"):
            body = text[len("static-interface:"):].strip()
            current["staticInterface"] = [part for part in body.split(", ") if part]
        elif current is not None and text.startswith("protected:"):
            body = text[len("protected:"):].strip()
            current["protected"] = [part for part in body.split(", ") if part]
        elif current is not None and text.startswith("members ("):
            body = text.split("): ", 1)[1] if "): " in text else ""
            entries = [entry for entry in body.split(", ") if entry]
            current["members"] = sorted({entry.split(" : ")[0] for entry in entries})
            owners = {}
            for entry in entries:
                name = entry.split(" : ")[0]
                if " @" not in entry:
                    continue
                simple = entry.rsplit(" @", 1)[1].rsplit(".", 1)[-1]
                owners.setdefault(name, set()).add(simple)
            current["owners"] = {name: sorted(declared) for name, declared in owners.items()}
    return found


def main():
    path = sys.argv[1]
    out = sys.argv[sys.argv.index("--out") + 1] if "--out" in sys.argv else None
    records = [json.loads(line) for line in open(path) if line.strip()]
    projects = {}
    if os.path.exists(path + ".projects"):
        for line in open(path + ".projects"):
            if line.strip():
                p = json.loads(line)
                p["processorpath"] = processor_path(p["project"])
                projects[p["project"]] = p
    by_file = collections.defaultdict(list)
    for r in records:
        by_file[(r["project"], r["path"])].append(r)
    rows = []
    for (project, file), group in sorted(by_file.items()):
        sites = sorted({"@%d:%d" % tuple(r["receiverUTF16"]) for r in group})
        oracle = run_oracle(file, sites, projects.get(project, {}))
        for r in group:
            o = oracle.get("@%d:%d" % tuple(r["receiverUTF16"]))
            engine = set(r["members"])
            if o is None:
                verdict, extra, missing = "unmatched", [], []
            elif o.get("type") == "<package>":
                # A package select has no members. It is not a missing type.
                verdict, extra, missing = "package", [], []
            elif o.get("members") is None:
                verdict, extra, missing = "javac-no-type", [], []
            else:
                javac = set(o["members"])
                extra, missing = sorted(engine - javac), sorted(javac - engine)
                verdict = "equivalent" if not extra and not missing else "engine-invalid" if not missing else "engine-missing" if not extra else "both"
                # Object's protected clone()/finalize() through a qualified receiver (JLS 6.6.2.1) is a separate,
                # pre-existing access-check question; keep it apart from a wrong receiver type.
                diff = set(extra) | set(missing)
                if verdict != "equivalent" and diff <= {"clone", "finalize"}:
                    verdict += " (only protected clone/finalize)"
                static_names = set(o.get("staticInterface") or [])
                if verdict != "equivalent" and static_names and diff <= static_names:
                    verdict += " (static interface method)"
            rows.append((verdict, r, extra, missing, o))
    lines = []
    lines.append("MEMBER-SET CLASSIFICATION (%d non-exact compared sites)" % len(rows))
    counts = collections.Counter(v for v, *_ in rows)
    for verdict, n in counts.most_common():
        lines.append("  %6d  %s" % (n, verdict))
    lines.append("")
    lines.append("BY AUDIT BUCKET x VERDICT")
    cross = collections.Counter((r["bucket"], v) for v, r, *_ in rows)
    for (bucket, verdict), n in sorted(cross.items()):
        lines.append("  %6d  %-70s %s" % (n, bucket, verdict))
    lines.append("")
    lines.append("SITES THAT ARE NOT EQUIVALENT")
    for verdict, r, extra, missing, o in rows:
        if verdict == "equivalent":
            continue
        lines.append("  [%s] %s/%s:%d | %s | javac %s | engine %s | bucket %s | engine-only %s | javac-only %s" % (
            verdict, r["project"], os.path.basename(r["path"]), r["line"], r["receiver"], r["javac"], r["engineRaw"],
            r["bucket"], extra[:12], missing[:12]))
    lines.append("")
    lines.append("PROTECTED ACCESS (the whole name diff is protected names; verdicts above are unchanged)")
    protected_only = []
    clone_only = 0
    for verdict, r, extra, missing, o in rows:
        if o is None:
            continue
        diff = set(extra) | set(missing)
        protected = set(o.get("protected") or [])
        if diff and protected and diff <= protected:
            protected_only.append((r, sorted(diff)))
            if diff <= {"clone", "finalize"}:
                clone_only += 1
    lines.append("  %6d  sites" % len(protected_only))
    lines.append("  %6d  of those, only clone/finalize" % clone_only)
    lines.append("  %6d  other protected names" % (len(protected_only) - clone_only))

    def receiver_simple(raw):
        if not raw or raw in ("nil", "<none>", "<package>"):
            return None
        base = raw.split("<", 1)[0].strip().replace("[]", "")
        if not base or base.startswith("<"):
            return None
        return base.rsplit(".", 1)[-1]

    lines.append("")
    lines.append("OVERRIDE / OWNERSHIP (simple declaring name; only non-exact sites, and only names both sides list)")
    mismatches = []
    compared = 0
    for verdict, r, extra, missing, o in rows:
        if not o or not o.get("owners") or "origins" not in r:
            continue
        compared += 1
        engine = {}
        for item in r.get("origins") or []:
            if "@" not in item:
                continue
            label, origin = item.rsplit("@", 1)
            engine.setdefault(label, set()).add(origin)
        receiver = receiver_simple(r.get("engineRaw"))
        bad = []
        for name, declared in o["owners"].items():
            if name not in engine and name not in set(r.get("members") or []):
                continue
            got = set(engine.get(name) or set())
            if not got and receiver:
                got = {receiver}
            got = {receiver if part == "" and receiver else part for part in got}
            got.discard("")
            if got and set(declared) != got:
                bad.append((name, sorted(got), declared))
        if bad:
            mismatches.append((r, bad))
    lines.append("  %6d  sites compared" % compared)
    lines.append("  %6d  sites whose declaring class disagrees" % len(mismatches))
    lines.append("  %6d  members" % sum(len(bad) for _, bad in mismatches))
    for r, bad in mismatches[:40]:
        shown = ", ".join("%s engine %s javac %s" % (name, eng, jav) for name, eng, jav in bad[:4])
        lines.append("  %s/%s:%d | %s | %s" % (r["project"], os.path.basename(r["path"]), r["line"], r["receiver"], shown))
    text = "\n".join(lines) + "\n"
    if out:
        open(out, "w").write(text)
    print(text)


if __name__ == "__main__":
    main()
