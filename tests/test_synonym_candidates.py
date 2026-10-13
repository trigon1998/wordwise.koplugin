#!/usr/bin/env python3
"""Pure candidate-ranking checks; does not require downloading WordNet."""
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from build_synonym_candidates import rank_same_synset, normalized

levels = {
    ("easy", "adjective"): {"A1"},
    ("straightforward", "adjective"): {"B2"},
    ("difficult", "adjective"): {"C1"},
    ("complex", "adjective"): {"B1"},
    ("very obscure", ""): {"C2"},
}
assert normalized("easy_word") == "easy word"
assert rank_same_synset(
    "difficult", "adjective", "C1",
    ["difficult", "easy", "complex", "straightforward", "very obscure", "unknown"],
    levels,
) == ["easy", "complex", "straightforward"]
assert rank_same_synset("difficult", "adjective", "B1",
    ["difficult", "straightforward", "complex"], levels) == ["complex"]
assert rank_same_synset("easy", "adjective", "A1",
    ["easy", "very obscure", "random"], levels) == []
print("same_synset_cefr_candidates_are_unapproved_and_conservative_ok")
