from collections import defaultdict
from pathlib import Path
import sys
import types

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
sys.modules.setdefault("wn", types.SimpleNamespace(Wordnet=None))

import build_cefr_wordnet_dict as builder


class FakeSynset:
    def __init__(self, key, definition):
        self.id = key
        self._definition = definition

    def definition(self):
        return self._definition


class FakeSense:
    def __init__(self, synset, count):
        self._synset = synset
        self._count = count

    def synset(self):
        return self._synset

    def counts(self):
        return [self._count]


class FakeWord:
    def __init__(self, lemma, pos, senses):
        self._lemma = lemma
        self.pos = pos
        self._senses = senses

    def lemma(self):
        return self._lemma

    def senses(self):
        return self._senses


proper = FakeSynset("proper-n", "United States comedian remembered for television")
common = FakeSynset("common-n", "a round object used in games")
shape = FakeSynset("shape-n", "an object with a spherical shape")
formal = FakeSynset("formal-n", "a lavish formal dance")

# Two lexical entries with the same normalized spelling reproduce the old bug:
# each entry used to receive its own max-senses slice.
fake_words = [
    FakeWord("Ball", "n", [FakeSense(proper, 100)]),
    FakeWord("ball", "n", [FakeSense(common, 10), FakeSense(shape, 8), FakeSense(formal, 2)]),
]
builder.wn.Wordnet = lambda _: types.SimpleNamespace(words=lambda: fake_words)

levels = defaultdict(set)
levels[("ball", "noun")].add("A2")
levels[("ball", "")].add("A2")
rows, seen = [], set()
used = builder.load_wordnet(levels, rows, seen, max_senses_per_word=2)

assert used == 2
assert len(rows) == 2
assert [row[2] for row in rows] == [common.definition(), shape.definition()]
assert [row[7] for row in rows] == [1, 2]
assert all(row[0] == "ball" for row in rows)

print("wordnet_builder_cap_and_ranking_ok")
