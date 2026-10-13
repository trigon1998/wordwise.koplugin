#!/usr/bin/env python3
"""No human approval = no label. Unit tests use a synthetic SQLite dictionary."""
import csv
import sqlite3
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from export_approved_sense_labels import export_rows, valid_label

with tempfile.TemporaryDirectory() as d:
    directory = Path(d)
    db = directory / "db.sqlite"
    csvpath = directory / "review.csv"
    con = sqlite3.connect(db)
    con.execute(
        "CREATE TABLE entries(sense_key TEXT, word TEXT, pos TEXT, source TEXT, full_def TEXT)"
    )
    con.execute(
        "INSERT INTO entries VALUES (?,?,?,?,?)",
        ("a" * 16, "perfunctory", "adjective",
         "oewn:2024:ewn-00123456-a", "done without care or interest"),
    )
    con.commit()
    con.close()

    def save(**updates):
        values = dict(
            sense_key="a" * 16, word="perfunctory",
            pos="adjective", source="oewn:2024:ewn-00123456-a",
            definition="done without care or interest",
            candidate="cursory", other_candidates="",
            kind="synonym", review_status="APPROVED",
            reviewer_1="editor_a", reviewer_2="editor_b",
            review_note="checked same synset and wording",
        )
        values.update(updates)
        with csvpath.open("w", encoding="utf8", newline="") as fh:
            writer = csv.DictWriter(fh, fieldnames=values)
            writer.writeheader()
            writer.writerow(values)

    save()
    approved = list(export_rows(csvpath, db))
    assert len(approved) == 1
    assert approved[0][-2:] == ("cursory", "approved")
    save(review_status="PENDING")
    assert list(export_rows(csvpath, db)) == []
    save(reviewer_2="editor_a")
    try:
        list(export_rows(csvpath, db))
        assert False, "single reviewer must be rejected"
    except ValueError:
        pass
    save(source="oewn:2024:ewn-other-a")
    try:
        list(export_rows(csvpath, db))
        assert False, "wrong synset must be rejected"
    except ValueError:
        pass
    save(definition="a different sense")
    try:
        list(export_rows(csvpath, db))
        assert False, "changed definition needs new review"
    except ValueError:
        pass
    assert valid_label("brief explanation")
    assert not valid_label("a" * 71)
print("two_reviewers_and_exact_sense_identity_export_guards_ok")
