#!/usr/bin/env python3
"""Generate *unapproved* same-synset synonym candidates for human review.

Never ship this output as a Word Wise hint database. Its candidates are
evidence for review, not a guarantee of interchangeability in sentences.

Requires: pip install wn && python -m wn download oewn:2024
Uses the exact Open English WordNet edition of the bundled Word Wise DB.
"""
import argparse
import csv
import re
import sqlite3
from collections import defaultdict
from pathlib import Path

CEFR = {"A1": 1, "A2": 2, "B1": 3, "B2": 4, "C1": 5, "C2": 6}
POS = {"noun": "n", "verb": "v", "adjective": "a", "adverb": "r"}
SOURCE_PREFIX = "oewn:2024:"


def normalized(value):
    return " ".join((value or "").lower().replace("_", " ").split())


def load_cefr_profiles(paths):
    levels = defaultdict(set)
    for path in paths:
        with Path(path).open(encoding="utf-8-sig", newline="") as fh:
            for row in csv.DictReader(fh):
                term = normalized(row.get("headword") or row.get("word"))
                level = (row.get("CEFR") or row.get("level") or "").strip().upper()
                pos = (row.get("pos") or "").strip().lower()
                if term and level in CEFR:
                    levels[(term, pos)].add(level)
                    levels[(term, "")].add(level)
    return levels


def rank_same_synset(word, part_of_speech, target_level, lemma_list, levels):
    """Only suggest strictly simpler CEFR-labelled alternatives in this synset.

    This is a candidate ranking heuristic, not an approval for display.
    """
    original = normalized(word)
    ranked = []
    for raw in lemma_list:
        term = normalized(raw)
        if term == original or len(term) < 3 or len(term) > 24:
            continue
        if not re.fullmatch(r"[a-z]+(?:[- ][a-z]+){0,2}", term):
            continue
        label_levels = levels.get((term, part_of_speech)) or levels.get((term, ""))
        if not label_levels:
            continue  # unknown vocabulary difficulty: do not call this simpler
        best = min(CEFR[level] for level in label_levels)
        if best > CEFR.get(target_level, 0):
            continue
        ranked.append((best, len(term.split()), len(term), term))
    ranked.sort()
    return [candidate[-1] for candidate in ranked]


def rows_for_review(db_path, lexicon, levels, limit=None):
    con = sqlite3.connect(db_path)
    con.row_factory = sqlite3.Row
    query = ("SELECT word, pos, cefr_level, sense_key, source, full_def "
             "FROM entries WHERE source LIKE 'oewn:2024:%' ORDER BY word, sense_rank")
    synset_cache = {}
    n = 0
    try:
        for row in con.execute(query):
            source = row["source"]
            if not source or not source.startswith(SOURCE_PREFIX):
                continue
            synset_id = source[len(SOURCE_PREFIX):]
            if synset_id not in synset_cache:
                # Using wn's exact synset ID prevents joining unrelated senses
                # merely because the lemma spelling is identical.
                import wn
                try:
                    synset = wn.synset(synset_id, lexicon="oewn:2024")
                    synset_cache[synset_id] = (
                        [w.lemma() for w in synset.words()], synset.pos)
                except (KeyError, ValueError, wn.Error):
                    synset_cache[synset_id] = ([], None)
            lemma_list, synset_pos = synset_cache[synset_id]
            expected = POS.get(row["pos"])
            if expected and synset_pos and expected != synset_pos:
                continue
            alternatives = rank_same_synset(
                row["word"], row["pos"] or "", row["cefr_level"],
                lemma_list, levels,
            )
            if alternatives:
                yield {
                    "sense_key": row["sense_key"], "word": row["word"],
                    "pos": row["pos"], "source": source,
                    "definition": row["full_def"],
                    "candidate": alternatives[0],
                    "other_candidates": " | ".join(alternatives[1:]),
                    "kind": "synonym", "review_status": "PENDING",
                    "reviewer_1": "", "reviewer_2": "", "review_note": "",
                }
                n += 1
                if limit and n >= limit:
                    break
    finally:
        con.close()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--db", default="wordwise.db")
    ap.add_argument("--cefrj", default="tools/cefrj-vocabulary-profile-1.5.csv")
    ap.add_argument("--octanove", default="tools/octanove-vocabulary-profile-c1c2-1.0.csv")
    ap.add_argument("--out", default="synonym_review_candidates.csv")
    ap.add_argument("--limit", type=int, default=0)
    args = ap.parse_args()
    import wn
    wn.Wordnet("oewn:2024")  # fail early when corpus is not installed
    levels = load_cefr_profiles([args.cefrj, args.octanove])
    fieldnames = [
        "sense_key", "word", "pos", "source", "definition",
        "candidate", "other_candidates", "kind", "review_status",
        "reviewer_1", "reviewer_2", "review_note",
    ]
    with Path(args.out).open("w", newline="", encoding="utf-8") as fh:
        writer = csv.DictWriter(fh, fieldnames)
        writer.writeheader()
        writer.writerows(rows_for_review(
            args.db, wn.Wordnet("oewn:2024"), levels, args.limit or None
        ))


if __name__ == "__main__":
    main()
