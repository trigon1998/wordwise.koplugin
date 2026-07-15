#!/usr/bin/env python3
"""Convert a Kindle Word Wise dictionary (WordWise.kll.en.en.db) into the
canonical schema the KOReader Word Wise plugin reads.

Canonical schema (source-agnostic — the plugin never cares where it came from):
    entries(word TEXT PRIMARY KEY COLLATE NOCASE,
            short_def TEXT NOT NULL,
            difficulty INTEGER NOT NULL,   -- 1 rarest .. 5 most common
            pos TEXT)

Difficulty is Kindle's hint_level, taken from the wisecreator frequency
lists 2.txt..5.txt (5 = most common word, shown only at "more hints";
1 = rarest, always shown). Same semantics the plugin already uses:
show a word when its difficulty <= the user's chosen hint level.

This reads Amazon/Merriam-Webster proprietary data and is for PERSONAL use
only — the resulting DB is never bundled or distributed with the plugin.
"""
import base64
import re
import sqlite3
import sys

SRC = sys.argv[1] if len(sys.argv) > 1 else "WordWise.kll.en.en.db"
OUT = sys.argv[2] if len(sys.argv) > 2 else "wordwise_kindle_en.db"

POS = {0: "noun", 1: "verb", 2: "adjective", 3: "adverb", 4: "article",
       5: "number", 6: "conjunction", 7: "other", 8: "preposition",
       9: "pronoun", 10: "particle", 11: "punctuation"}


def load_freq(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return set(w.strip().lower() for w in f if w.strip())
    except FileNotFoundError:
        return set()


# hint level: most-common list wins (matches db2csv.py order 5>4>3>2>1)
L5, L4, L3, L2 = (load_freq(f"{n}.txt") for n in (5, 4, 3, 2))


def difficulty(word):
    if word in L5:
        return 5
    if word in L4:
        return 4
    if word in L3:
        return 3
    if word in L2:
        return 2
    return 1


def decode(b):
    if not b:
        return None
    try:
        return base64.b64decode(b).decode("utf-8", "ignore").strip()
    except Exception:
        return None


def is_initialism(word, gloss):
    """True if the headword is just the initials of the gloss, i.e. an acronym
    expansion (led -> "light-emitting diode", gpa -> "grade point average").
    These collide with common words when lowercased (notably led = past tense
    of lead), so we skip such senses and let a real sense win instead."""
    toks = re.findall(r"[a-z]+", gloss.lower())
    if len(word) < 2 or len(toks) != len(word):
        return False
    return "".join(t[0] for t in toks) == word


src = sqlite3.connect(SRC)
lemma = dict(src.execute("SELECT id, lemma FROM lemmas"))

# best[word] = (sense_number, -corpus_count, short_def, pos)  -> min() picks
# the primary sense (lowest sense_number, then highest corpus_count).
best = {}
rows = src.execute(
    "SELECT term_lemma_id, sense_number, corpus_count, pos_type, short_def "
    "FROM senses WHERE short_def IS NOT NULL AND short_def <> ''")
for term_id, sense_no, cc, pos_type, sdef_b in rows:
    word = lemma.get(term_id)
    if not word:
        continue
    word = word.strip().lower()
    # single tokens only: multi-word terms never match a book word
    if not word or " " in word or not any(c.isalpha() for c in word):
        continue
    sdef = decode(sdef_b)
    if not sdef:
        continue
    # drop Merriam-Webster editorial placeholder entries
    up = sdef.upper()
    if "DO NOT USE THIS ENTRY" in up or "SEE MW LD" in up:
        continue
    # drop acronym-expansion senses (led -> "light-emitting diode"); a real
    # sense of the same surface word, if any, is kept instead.
    if is_initialism(word, sdef):
        continue
    key = (float(sense_no or 0), -(cc or 0))
    cur = best.get(word)
    if cur is None or key < cur[0]:
        best[word] = (key, sdef, POS.get(pos_type, "other"))
src.close()

out = sqlite3.connect(OUT)
out.executescript("""
PRAGMA journal_mode=OFF;
DROP TABLE IF EXISTS entries;
CREATE TABLE entries (
    word TEXT PRIMARY KEY COLLATE NOCASE,
    short_def TEXT NOT NULL,
    difficulty INTEGER NOT NULL,
    pos TEXT
);
""")
out.executemany(
    "INSERT OR REPLACE INTO entries(word, short_def, difficulty, pos) "
    "VALUES (?,?,?,?)",
    [(w, v[1], difficulty(w), v[2]) for w, v in best.items()])
out.commit()

n = out.execute("SELECT COUNT(*) FROM entries").fetchone()[0]
dist = out.execute(
    "SELECT difficulty, COUNT(*) FROM entries GROUP BY difficulty ORDER BY difficulty"
).fetchall()
out.execute("VACUUM")
out.close()
print(f"wrote {OUT}: {n} entries")
print("difficulty distribution (1 rarest .. 5 most common):", dict(dist))
