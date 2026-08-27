#!/usr/bin/env python3
"""Build Word Wise's CEFR-aware SQLite dictionary.

Inputs:
  --cefrj       CEFR-J vocabulary CSV (headword,pos,CEFR,...)
  --octanove    optional Octanove C1/C2 CSV
  --glosses     word<TAB>short gloss [<TAB>pos [<TAB>sense_key [<TAB>source]]]

The builder never invents a CEFR level. Gloss rows without a matching audited
CEFR source are skipped and reported, so a release can inspect coverage before
shipping. Multiple gloss rows for the same word are preserved as separate
senses.
"""
import argparse
import csv
import hashlib
import sqlite3
from pathlib import Path

LEVELS = {"A1", "A2", "B1", "B2", "C1", "C2"}
POS_ALIASES = {
    "noun": "noun", "verb": "verb", "adjective": "adjective", "adverb": "adverb",
    "determiner": "determiner", "preposition": "preposition", "pronoun": "pronoun",
    "conjunction": "conjunction", "auxiliary": "verb", "modal": "verb",
}


def norm_word(value):
    return " ".join((value or "").strip().lower().split())


def norm_pos(value):
    return POS_ALIASES.get((value or "").strip().lower(), (value or "").strip().lower())


def add_level(levels, word, pos, level):
    level = (level or "").strip().upper()
    if level not in LEVELS:
        return
    key = (norm_word(word), norm_pos(pos))
    levels.setdefault(key, set()).add(level)
    levels.setdefault((key[0], ""), set()).add(level)


def load_cefr_csv(path, levels):
    with open(path, encoding="utf-8-sig", newline="") as f:
        for row in csv.DictReader(f):
            add_level(levels, row.get("headword"), row.get("pos"), row.get("CEFR"))


def load_octanove_csv(path, levels):
    with open(path, encoding="utf-8-sig", newline="") as f:
        for row in csv.DictReader(f):
            word = row.get("headword") or row.get("word") or row.get("Headword")
            pos = row.get("pos") or row.get("POS") or ""
            level = row.get("CEFR") or row.get("level") or row.get("Level")
            add_level(levels, word, pos, level)


def choose_level(levels):
    # If sources disagree, choose the harder level only when all source labels
    # agree; otherwise use the lower/earlier level conservatively.
    order = ["A1", "A2", "B1", "B2", "C1", "C2"]
    return min(levels, key=order.index)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cefrj", required=True)
    ap.add_argument("--octanove")
    ap.add_argument("--glosses", required=True)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    cefr = {}
    load_cefr_csv(args.cefrj, cefr)
    if args.octanove:
        load_octanove_csv(args.octanove, cefr)

    rows = []
    skipped = 0
    seen = set()
    with open(args.glosses, encoding="utf-8-sig") as f:
        for line_no, line in enumerate(f, 1):
            parts = line.rstrip("\n").split("\t")
            if len(parts) < 2:
                continue
            word, gloss = norm_word(parts[0]), " ".join(parts[1].split())
            pos = norm_pos(parts[2]) if len(parts) >= 3 else ""
            sense_key = parts[3].strip() if len(parts) >= 4 and parts[3].strip() else ""
            source = parts[4].strip() if len(parts) >= 5 else "open_glosses.tsv"
            if not word or not gloss:
                continue
            level_set = cefr.get((word, pos))
            if level_set is None:
                level_set = cefr.get((word, ""))
            if not level_set:
                skipped += 1
                continue
            level = choose_level(level_set)
            if not sense_key:
                sense_key = hashlib.sha1(f"{word}\x1f{pos}\x1f{gloss}".encode()).hexdigest()[:16]
            dedupe_key = (word, gloss, level, pos, sense_key)
            if dedupe_key in seen:
                continue
            seen.add(dedupe_key)
            rows.append((word, gloss, level, pos or None, sense_key, source or None))

    out = Path(args.out)
    if out.exists(): out.unlink()
    con = sqlite3.connect(out)
    con.executescript("""
        PRAGMA journal_mode=OFF;
        CREATE TABLE entries(
            id INTEGER PRIMARY KEY,
            word TEXT NOT NULL COLLATE NOCASE,
            short_def TEXT NOT NULL,
            cefr_level TEXT NOT NULL CHECK(cefr_level IN ('A1','A2','B1','B2','C1','C2')),
            pos TEXT,
            sense_key TEXT NOT NULL UNIQUE,
            source TEXT
        );
        CREATE INDEX entries_word_idx ON entries(word COLLATE NOCASE);
        CREATE INDEX entries_cefr_idx ON entries(cefr_level);
    """)
    con.executemany("INSERT INTO entries(word,short_def,cefr_level,pos,sense_key,source) VALUES(?,?,?,?,?,?)", rows)
    con.commit()
    con.close()
    print(f"wrote {out}: {len(rows)} senses; skipped {skipped} gloss rows without CEFR mapping")


if __name__ == "__main__":
    main()
