#!/usr/bin/env python3
"""Build a CEFR-aware, multi-sense Word Wise dictionary from open sources.

The CEFR-J and Octanove files provide level labels; Open English WordNet
provides definitions and multiple senses. Project glosses in open_glosses.tsv
are retained as curated entries and take precedence over duplicate WordNet
senses. No Kindle/Amazon data is read.
"""
import argparse
import csv
import hashlib
import sqlite3
from collections import defaultdict
from pathlib import Path

import wn

LEVEL_ORDER = {"A1": 1, "A2": 2, "B1": 3, "B2": 4, "C1": 5, "C2": 6}
POS_MAP = {"n": "noun", "v": "verb", "a": "adjective", "s": "adjective", "r": "adverb"}
POS_ALIASES = {"auxiliary": "verb", "modal": "verb"}


def norm_word(value):
    return " ".join((value or "").strip().lower().split())


def norm_pos(value):
    value = (value or "").strip().lower()
    return POS_ALIASES.get(value, value)


def add_cefr(levels, word, pos, level):
    word, pos, level = norm_word(word), norm_pos(pos), (level or "").strip().upper()
    if word and level in LEVEL_ORDER:
        levels[(word, pos)].add(level)
        levels[(word, "")].add(level)


def load_profile(path, levels):
    with open(path, encoding="utf-8-sig", newline="") as f:
        for row in csv.DictReader(f):
            add_cefr(levels, row.get("headword") or row.get("word"), row.get("pos"), row.get("CEFR") or row.get("level"))


def choose_level(values):
    # Conservative choice for conflicting labels: the easier label wins.
    return min(values, key=lambda value: LEVEL_ORDER[value])


def add_row(rows, seen, word, gloss, level, pos, source, sense_key=None):
    word = norm_word(word)
    gloss = " ".join((gloss or "").split()).strip()
    pos = norm_pos(pos)
    if not word or not gloss or level not in LEVEL_ORDER:
        return
    sense_key = sense_key or hashlib.sha1(f"{word}\x1f{pos}\x1f{gloss}".encode()).hexdigest()[:16]
    key = (word, gloss, level, pos, sense_key)
    if key in seen:
        return
    seen.add(key)
    rows.append((word, gloss, level, pos or None, sense_key, source))


def load_curated_glosses(path, levels, rows, seen):
    skipped = 0
    with open(path, encoding="utf-8-sig") as f:
        for line in f:
            parts = line.rstrip("\n").split("\t")
            if len(parts) < 2:
                continue
            word, gloss = norm_word(parts[0]), parts[1]
            pos = norm_pos(parts[2]) if len(parts) >= 3 else ""
            sense_key = parts[3].strip() if len(parts) >= 4 else None
            source = parts[4].strip() if len(parts) >= 5 else "open_glosses.tsv"
            level_values = levels.get((word, pos)) or levels.get((word, ""))
            if not level_values:
                skipped += 1
                continue
            add_row(rows, seen, word, gloss, choose_level(level_values), pos, source, sense_key)
    return skipped


def load_wordnet(levels, rows, seen, max_senses_per_word):
    lexicon = wn.Wordnet("oewn:2024")
    wanted = {word for word, _ in levels}
    used = 0
    for word_obj in lexicon.words():
        word = norm_word(word_obj.lemma())
        if word not in wanted or not word.isalpha():
            continue
        pos = POS_MAP.get(word_obj.pos, "")
        level_values = levels.get((word, pos)) or levels.get((word, ""))
        if not level_values:
            continue
        level = choose_level(level_values)
        for synset in word_obj.synsets()[:max_senses_per_word]:
            definition = synset.definition()
            add_row(rows, seen, word, definition, level, pos, f"oewn:2024:{synset.id}")
            used += 1
    return used


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cefrj", required=True)
    ap.add_argument("--octanove", required=True)
    ap.add_argument("--glosses", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--max-senses-per-word", type=int, default=8)
    args = ap.parse_args()

    levels = defaultdict(set)
    load_profile(args.cefrj, levels)
    load_profile(args.octanove, levels)

    rows, seen = [], set()
    skipped = load_curated_glosses(args.glosses, levels, rows, seen)
    wordnet_rows = load_wordnet(levels, rows, seen, args.max_senses_per_word)

    out = Path(args.out)
    if out.exists():
        out.unlink()
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
    print(f"wrote {out}: {len(rows)} senses; added {wordnet_rows} WordNet senses; skipped {skipped} curated rows without CEFR mapping")


if __name__ == "__main__":
    main()
