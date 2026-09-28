#!/usr/bin/env python3
"""Upgrade an existing Word Wise database to short_def + full_def."""

import argparse
import sqlite3

from gloss_compactor import compact_gloss, validate_short_gloss


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--db", required=True)
    args = parser.parse_args()

    con = sqlite3.connect(args.db)
    columns = {row[1] for row in con.execute("PRAGMA table_info(entries)")}
    if "full_def" not in columns:
        con.execute("ALTER TABLE entries ADD COLUMN full_def TEXT")

    rows = list(con.execute(
        "SELECT id, word, short_def, COALESCE(full_def, short_def) FROM entries"
    ))
    updates = []
    changed = 0
    for row_id, word, old_short, full_def in rows:
        short_def = compact_gloss(word, full_def)
        if not validate_short_gloss(short_def):
            raise ValueError(f"invalid compact gloss for {word!r}: {short_def!r}")
        changed += short_def != old_short
        updates.append((short_def, full_def, row_id))

    con.executemany(
        "UPDATE entries SET short_def = ?, full_def = ? WHERE id = ?",
        updates,
    )
    con.commit()
    con.execute("VACUUM")
    con.close()
    print(f"updated {len(updates)} senses; shortened {changed}")


if __name__ == "__main__":
    main()
