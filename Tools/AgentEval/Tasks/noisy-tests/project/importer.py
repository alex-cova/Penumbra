"""Imports customer rows, skipping the ones already seen."""


def normalize_email(email):
    return email.strip()


def import_rows(rows):
    """Returns the rows to keep. A row is a duplicate when its email was already imported."""
    seen = set()
    kept = []
    for number, row in enumerate(rows, start=1):
        key = normalize_email(row["email"])
        if key in seen:
            print(f"[import] row {number}: duplicate {key!r}, skipped", flush=True)
            continue
        seen.add(key)
        kept.append(row)
        print(f"[import] row {number}: ok {key!r} ({row['name']}, {row['plan']}, {row['country']})", flush=True)
    print(f"[import] done: kept {len(kept)} of {len(rows)}", flush=True)
    return kept
