#!/usr/bin/env python3
"""Build the plugin's bundled open Word Wise dictionary (wordwise.db).

The dictionary is 100% distributable — it contains no Kindle/Merriam-Webster
content. It is assembled from three open ingredients:

  * word list  : Open English WordNet lemmas (permissive license)
  * difficulty : word-frequency (Zipf) from the `wordfreq` package
  * glosses    : short definitions written for this project (open_glosses.tsv)

Only "hard" words are kept: those whose Zipf frequency is below the common
threshold. Difficulty 1 = rarest (always shown) .. 5 = most common (shown only
at the highest hint level). A word is glossed when difficulty <= hint level.

Canonical output schema (what the plugin reads):
  entries(word TEXT PRIMARY KEY COLLATE NOCASE,
          short_def TEXT NOT NULL,
          difficulty INTEGER NOT NULL,
          pos TEXT)

Usage:
  # 1. (re)generate the hard-word list with difficulty + POS
  python3 build_open_dict.py candidates > candidates.tsv     # needs: wn, wordfreq

  # 2. build the DB from the word list + the gloss source
  python3 build_open_dict.py build --glosses open_glosses.tsv --out wordwise.db

`open_glosses.tsv` is the editable gloss source (word<TAB>gloss). To improve a
definition, edit that file and re-run step 2 — no model access required.
"""
import argparse
import os
import sqlite3
import sys

ZIPF_MAX = 4.3    # words at/above this are too common to gloss
ZIPF_MIN = 2.0    # words below this are too obscure for a reading dictionary
POS = {"n": "noun", "v": "verb", "a": "adjective", "s": "adjective", "r": "adverb"}


def band(z):
    if z >= ZIPF_MAX:
        return None
    if z < 2.8:
        return 1
    if z < 3.2:
        return 2
    if z < 3.6:
        return 3
    if z < 4.0:
        return 4
    return 5


def cmd_candidates(_args):
    from wordfreq import zipf_frequency
    import wn
    W = wn.Wordnet("oewn:2024")
    seen = {}
    for word in W.words():
        lem = word.lemma()
        # lower-case lemmas only -> excludes WordNet's capitalised proper nouns
        if lem.isalpha() and lem.islower() and len(lem) >= 3:
            seen.setdefault(lem, word.pos)
    for w in sorted(seen):
        z = zipf_frequency(w, "en")
        if z < ZIPF_MIN:
            continue
        d = band(z)
        if d is None:
            continue
        sys.stdout.write(f"{w}\t{d}\t{POS.get(seen[w], 'other')}\n")


def cmd_build(args):
    # candidates: word -> (difficulty, pos)
    cand = {}
    if args.candidates and os.path.exists(args.candidates):
        for ln in open(args.candidates, encoding="utf-8"):
            w, d, p = ln.rstrip("\n").split("\t")
            cand[w] = (int(d), p)
    else:
        # derive on the fly if no cached candidates file was supplied
        from wordfreq import zipf_frequency
        import wn
        W = wn.Wordnet("oewn:2024")
        seen = {}
        for word in W.words():
            lem = word.lemma()
            if lem.isalpha() and lem.islower() and len(lem) >= 3:
                seen.setdefault(lem, word.pos)
        for w in seen:
            z = zipf_frequency(w, "en")
            d = band(z)
            if z >= ZIPF_MIN and d is not None:
                cand[w] = (d, POS.get(seen[w], "other"))

    rows = []
    for ln in open(args.glosses, encoding="utf-8"):
        if "\t" not in ln:
            continue
        w, g = ln.rstrip("\n").split("\t", 1)
        w, g = w.strip().lower(), " ".join(g.split()).strip()
        if not g:
            continue
        d, p = cand.get(w, (1, "other"))
        rows.append((w, g, d, p))

    if os.path.exists(args.out):
        os.remove(args.out)
    con = sqlite3.connect(args.out)
    con.executescript("""PRAGMA journal_mode=OFF;
        CREATE TABLE entries(word TEXT PRIMARY KEY COLLATE NOCASE,
            short_def TEXT NOT NULL, difficulty INTEGER NOT NULL, pos TEXT);""")
    con.executemany("INSERT OR IGNORE INTO entries VALUES(?,?,?,?)", rows)
    con.commit()
    n = con.execute("SELECT COUNT(*) FROM entries").fetchone()[0]
    con.execute("VACUUM")
    con.close()
    print(f"wrote {args.out}: {n} entries")


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("candidates", help="print hard-word list (word<TAB>difficulty<TAB>pos)")
    b = sub.add_parser("build", help="build wordwise.db from glosses")
    b.add_argument("--glosses", default="open_glosses.tsv")
    b.add_argument("--candidates", default="candidates.tsv")
    b.add_argument("--out", default="wordwise.db")
    args = ap.parse_args()
    (cmd_candidates if args.cmd == "candidates" else cmd_build)(args)
