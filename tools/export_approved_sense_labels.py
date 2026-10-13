#!/usr/bin/env python3
"""Export approved, double-reviewed sense hints with fail-closed identity checks.

Unreviewed synonym candidates never enter the distributed Word Wise plugin.
Format matches wordwise_sense_labels.lua.
"""
import argparse
import csv
import sqlite3
from pathlib import Path

COLUMNS = ("sense_key", "word", "pos", "source", "kind", "label")


def valid_label(text):
    return (isinstance(text, str) and 1 <= len(text) <= 70
            and len(text.split()) <= 6 and not any(ord(c) < 32 for c in text)
            and "\t" not in text and "\n" not in text)


def export_rows(review_csv, db_path):
    con = sqlite3.connect(db_path)
    con.row_factory = sqlite3.Row
    try:
        seen = set()
        with Path(review_csv).open(newline="", encoding="utf-8") as fh:
            for index, record in enumerate(csv.DictReader(fh), start=2):
                if record.get("review_status") != "APPROVED":
                    continue
                reviewer1, reviewer2 = (record.get("reviewer_1") or "").strip(), (
                    record.get("reviewer_2") or "").strip()
                if not reviewer1 or not reviewer2 or reviewer1 == reviewer2:
                    raise ValueError(f"line {index}: two different reviewers required")
                sense_key = record.get("sense_key", "")
                row = con.execute(
                    "SELECT word, pos, source, full_def FROM entries WHERE sense_key=?",
                    (sense_key,),
                ).fetchone()
                if not row:
                    raise ValueError(f"line {index}: sense_key not in Word Wise DB")
                for name in ("word", "pos", "source"):
                    if (record.get(name) or "") != (row[name] or ""):
                        raise ValueError(f"line {index}: {name} mismatch")
                if record.get("definition") != row["full_def"]:
                    raise ValueError(f"line {index}: definition changed, re-review required")
                if not (row["source"] or "").startswith("oewn:2024:"):
                    raise ValueError(f"line {index}: non-OEWN sense requires another workflow")
                label = (record.get("candidate") or "").strip()
                if (record.get("kind") not in {"synonym", "paraphrase"}
                        or not valid_label(label)):
                    raise ValueError(f"line {index}: invalid reviewed label")
                if label.lower() == row["word"].lower():
                    raise ValueError(f"line {index}: label repeats headword")
                if sense_key in seen:
                    raise ValueError(f"line {index}: duplicate approved sense")
                seen.add(sense_key)
                yield (
                    sense_key, row["word"], row["pos"] or "", row["source"],
                    record["kind"], label, "approved",
                )
    finally:
        con.close()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--reviewed", required=True, help="Editor-verified CSV")
    ap.add_argument("--db", default="wordwise.db")
    ap.add_argument("--out", default="wordwise_sense_labels.tsv")
    args = ap.parse_args()
    records = list(export_rows(args.reviewed, args.db))
    with Path(args.out).open("w", encoding="utf-8", newline="") as fh:
        fh.write("# sense_key\tword\tpos\tsource\tkind\tlabel\tstatus\n")
        for row in sorted(records):
            fh.write("\t".join(row) + "\n")
    print(f"approved {len(records)} reviewed sense labels")


if __name__ == "__main__":
    main()
