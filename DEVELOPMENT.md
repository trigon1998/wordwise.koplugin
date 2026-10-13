# Word Wise for KOReader Android — Development Guide

## Experimental pilot — sense-accurate simplified labels

This branch adds a second independent Inline source setting: `dictionary`
or `simplified`. The default is dictionary. Reviewed labels are loaded from
`wordwise_sense_labels.tsv`, mapped to exact
`(sense_key, word, part-of-speech, source)`. The `source` must identify an
Open English WordNet **2024 synset**. This alignment already exists in
`wordwise.db` for most OEWN records; curated non-OEWN entries fall back.

In `simplified` mode:
1. Try the exact reviewed label from `wordwise_sense_labels.lua`.
2. If missing, mismatched, or not approved: display the original WordNet
   definition and apply the selected Micro or Short display limit.
3. Never make a new synonym from an unrelated sense, hypernym, antonym or
   semantically similar embedding.
4. Existing sense choices, CEFR filters, and Known Words remain untouched.

The checked-in TSV has **no approved entries yet**; don't merge and publish
a release until the review data has sufficient audited coverage. Loading an
empty file is intentional and safe.

### Building review candidates (offline builder, not an on-device AI feature)

Install `wn` and the *exact* 2024 OEWN dataset, used by the original
dictionary builder:

```sh
python -m pip install wn
python -m wn download oewn:2024
python tools/build_synonym_candidates.py --db wordwise.db --out synonym_review_candidates.csv
```

The generator considers only alternative lemmas in the SAME WordNet synset,
limits them to a compact label, checks the part of speech, and favors
candidates with a CEFR label no harder than the current headword.
**These filters produce candidates, not proven interchangeable synonyms.**
CEFR is tagged at the word level, not necessarily the individual sense.

Editors must examine every candidate against its source full definition,
part of speech and register. Ambiguous words, phrasal verbs, culturally
specific references, slang, negatives and connotations should be audited
manually. A 1-to-3-word explanatory paraphrase is an acceptable replacement
when no *semantically equivalent* synonym is short, familiar and precise.

For a batch to be released, export only rows marked `APPROVED`, with two
distinct human review identifiers, using:

```sh
python tools/export_approved_sense_labels.py \
  --reviewed synonym_review_candidates.csv \
  --db wordwise.db \
  --out wordwise_sense_labels.tsv
```

The exporter rejects changes to the `sense_key`, `source`, `word`,
`pos` or full WordNet definition; it also refuses missing reviewers, duplicate
approved senses and invalid labels. Generated candidates are never inserted
without explicit double approval.

### Pre-release evaluation gates

These are **proposed release gates**, not achieved metrics:

- Conduct blinded editorial review of **at least 200 randomly sampled,
  proposed labels**, enriched with **100 ambiguous/polysemous senses**.
- Require **at least 98% sense-correctness** in independent review and
  adjudicate all reviewer disagreements. Record whether the concise label is
  actually *easier* to understand than the original WordNet gloss.
- Report **coverage** separately: proportion of total eligible senses with
  approved labels, and proportion of common words encountered in English
  reading pages with approved labels. Never optimize coverage by inventing
  unsupported synonyms.
- Regression-test examples across nouns, adjectives, verbs, adverbs, uncommon
  senses, register differences, unknown user-supplied DB schema, and user
  choices. Confirm that mismatched/unapproved labels fall back.
- Verify performance/memory on physical KOReader Android hardware; the
  on-device work is an O(1) lookup after a one-time small TSV load, not a
  network call.

## v0.2.15 — Dual display

The plugin now supports two interchangeable presentation modes, stored per book
as `wordwise_display_mode`:

- **tap** (default): subtle wavy underlines and non-modal definition bubble;
  existing KOReader line spacing remains unchanged
- **inline**: short labels above eligible words via `wordwise_inline.lua`,
  with temporary line-spacing expansion and safe restoration on mode switch

Inline labels are extracted by `wordwise_microgloss.lua` from the selected
WordNet sense, limited to four words/34 characters by default or six words/
50 characters with Inline detail. They do not invent new synonyms, infer
context, or require an online model. Tapping any *visible* inline label or
its word opens the existing full multi-sense dialog.

The two modes share CEFR filters, known words and saved senses; the inline
renderer retains collision guards and a top-edge fallback. The new modules
are mandatory in OTA archives and covered by headless Lua tests.

## 1. Project scope

This is an Android-focused offline KOReader vocabulary overlay fork of
[asxelot/wordwise.koplugin](https://github.com/asxelot/wordwise.koplugin).
It does not modify source book files or query AI services. The bundled
SQLite database is sourced from CEFR-J, Octanove and Open English WordNet.

**Current reader workflow:**

1. `WordWise:computePageHints()` traverses words on the visible reflowable page.
2. `wordwise_reading_level.lua` maps Basic → A2+, Intermediate → B1+, Advanced → C1+.
3. The page overlay paints a subtle wavy underline inside each eligible word box.
4. Tapping an underlined word creates a `wordwise_bubble.lua` definition bubble.
5. Tapping that bubble opens the existing `wordwise_hint_dialog.lua` sense picker
   with Know/Show, Dictionary and Cancel.
6. A tap outside the bubble dismisses it without turning a page; taps on
   unmarked text continue to the normal KOReader touch zones.

The six original CEFR bands and the multi-sense SQLite schema stay unchanged;
no semantic selection based on context is performed. A user-selected sense
continues to override the automatically chosen dictionary sense.

## 2. Source layout

- `main.lua`: reader lifecycle, visible-word scanning, underline painting,
  touch-zone dispatch, settings, persisted user choices, OTA UI
- `wordwise_bubble.lua`: short definition frame, anchor geometry and painting
- `wordwise_reading_level.lua`: three proficiency levels and backward mapping
  for old `wordwise_cefr_level` settings
- `wordwise_hint_dialog.lua`: complete dictionary meaning selection and actions
- `wordwise_db.lua`, `wordwise.db`: offline WordNet definitions and CEFR labels
- `wordwise_ota.lua`: release-asset verification and updater
- `tests/test_lua.lua`, `tests/test_cefr.py`, `tests/test_builder.py`:
  syntax, offline schema, UI invariants, vocabulary and updater regressions

The directory must be named `wordwise.koplugin` in KOReader's plugins path.

## 3. Reader integration

The plugin registers a ReaderView view module that paints onto the existing
page blitbuffer without creating a second document. It obtains visible-word
XPointer ranges and screen boxes from KOReader's reflowable/crengine interface.
Fixed-layout PDFs and DjVu are not supported.

**Do not increase line spacing** for underlines. At startup,
`restoreLegacyLineSpacing()` removes the old inline-gloss settings and restores
the saved spacing if the reader hasn't changed it. New activations never
call `setInterlineSpacePercent` except for this one-time migration.

Touch handling returns false on any unmarked word when no bubble is open,
preserving existing page-turn and selection behaviors. The popup and source
word are the only interactive areas owned by Word Wise; its simple bubble
is not a separate modal. Any page turn or reflow clears the bubble and
recomputes the visible word boxes.

## 4. Reading level mapping

| Mode | Minimum CEFR | Eligible bands |
| --- | --- | --- |
| Basic | A2 | A2, B1, B2, C1, C2 |
| Intermediate | B1 | B1, B2, C1, C2 |
| Advanced | C1 | C1, C2 |

Legacy setting values map A1/A2 → Basic, B1/B2 → Intermediate and C1/C2
→ Advanced, unless the new reading-level preference has already been saved.
Do not change or rebuild the database to achieve this filtering.

## 5. Database contract

The canonical schema is:

```sql
CREATE TABLE entries (
    id         INTEGER PRIMARY KEY,
    word       TEXT NOT NULL COLLATE NOCASE,
    short_def  TEXT NOT NULL,
    full_def   TEXT NOT NULL,
    cefr_level TEXT NOT NULL CHECK(cefr_level IN ('A1','A2','B1','B2','C1','C2')),
    pos        TEXT,
    sense_key  TEXT NOT NULL UNIQUE,
    source     TEXT
);

CREATE INDEX entries_word_idx ON entries(word COLLATE NOCASE);
CREATE INDEX entries_cefr_idx ON entries(cefr_level);
```

Every sense is a separate row. `short_def` is the glanceable overlay phrase; `full_def` preserves the complete attributed source definition shown in the popup. `sense_key` must be deterministic and unique so that saved selections remain stable across page turns. A practical fallback key is the normalized lemma, part of speech, and full definition joined with a non-printing separator; a builder may use a stronger stable identifier when the upstream source provides one.

`wordwise_db.lua` exposes two important lookup levels:

| Function | Purpose |
|---|---|
| `lookup(word)` | Returns the first usable sense for compatibility with simple callers. |
| `lookupAll(word)` | Returns every usable sense for context selection and popup display. |

The lookup layer performs conservative de-inflection for common plural, `-ed`, `-ing`, and `-ly` forms. It should not be expanded casually: an incorrect stem can cause a hint for a different lemma to appear on the page.

A user database placed at:

```text
<KOReader data directory>/wordwise/wordwise.db
```

takes precedence over the bundled database. The database is opened read-only by the runtime. Rebuild the database offline and replace it as a complete file; do not mutate the bundled file from inside KOReader.

## 6. Dictionary build pipeline

The preferred build command is:

```sh
cd tools
python3 build_cefr_wordnet_dict.py \\
  --cefrj cefrj-vocabulary-profile-1.5.csv \\
  --octanove octanove-vocabulary-profile-c1c2-1.0.csv \\
  --glosses open_glosses.tsv \\
  --out ../wordwise.db
```

The builder merges the CEFR-J and Octanove profiles, preserves curated project glosses, and adds multiple open WordNet senses for CEFR-mapped lemmas. `tools/gloss_compactor.py` deterministically extracts a short phrase capped at 72 characters and 12 words. It removes explanatory material from the inline form without replacing the source text: the complete WordNet definition remains in `full_def` with its attribution. Curated rows take precedence when the project has a better short gloss.

Before committing a rebuilt database, check:

```sh
python3 - <<'PY'
import sqlite3
con = sqlite3.connect('wordwise.db')
print(con.execute('select count(*) from entries').fetchone()[0])
print(con.execute('select cefr_level, count(*) from entries group by cefr_level order by cefr_level').fetchall())
print(con.execute('select word, count(*) from entries group by word having count(*) > 1 order by count(*) desc limit 10').fetchall())
PY
```

Do not add Kindle/Amazon-derived data to the public build. Keep raw source files and attribution in the repository so that another developer can reproduce the database.

## 7. Underline rendering and bubble geometry

`WordWise:paintHints()` paints a one-pixel gray wave near the bottom of
each matched word's screen box. There is no above-line gloss, measured-width
truncation, collision solver or enlarged line spacing.

`wordwise_bubble.lua` creates a light framed TextBoxWidget for the short
definition and a brief instruction to tap for more information. The bubble
is anchored above or below the tapped word and clamped to screen edges.
It is freed on page navigation, settings refresh, close, or replacement.

## 8. Interaction and popup

`onHintTap()` handles underlined-word taps, taps inside the bubble and
outside dismissal. Nonmatching taps must return false for KOReader.
The modal `wordwise_hint_dialog.lua` retains its full definition,
other senses, Know/Show, Dictionary and Cancel controls. Sense selections
persist in `state.lua`; known lemmas persist in `known_words.lua`.
These two files are stored under KOReader's data directory, not the plugin.

## 9. Persistent user state

User state must not be stored inside `wordwise.koplugin`, because a plugin update commonly replaces that directory. The current paths are:

```text
<KOReader data directory>/wordwise/known_words.lua
<KOReader data directory>/wordwise/state.lua
```

`known_words.lua` stores a table under `words`, keyed by normalized lemma. `state.lua` stores selected sense keys under `selected_senses`. The files are opened with KOReader's `LuaSettings` module, which provides `open`, `saveSetting`, and `flush` operations.[3]

An explicitly selected sense is always honored while it remains available and
the word is not marked known. The CEFR threshold selects which words receive a
hint by default; it must not silently replace a user's selected sense when one
lemma has senses carrying different CEFR labels.

The plugin includes a menu action named **Known words file** that displays the exact path on the device. This is useful for backup, troubleshooting, and migration. An updater must never purge or replace the KOReader data directory.

If the schema of user state changes, use a version field and a one-time migration rather than silently discarding old data:

```lua
state_version = 2
known_words = { ... }
selected_senses = { ... }
```

## 10. Local development

The project can be edited on a normal Linux workstation or in the sandbox. LuaJIT is the actual KOReader runtime; if a Lua executable is unavailable, the repository's syntax checks use the Python `luaparser` package as a syntax-level fallback.

Install the development-only Python dependencies if needed:

```sh
sudo pip3 install luaparser
```

Run the validation suite from the repository root:

```sh
python3 /home/ubuntu/check_lua_syntax.py
python3 tests/test_cefr.py
python3 -m py_compile tools/build_cefr_dict.py tools/build_cefr_wordnet_dict.py
```

The tests currently cover Lua syntax, Python syntax, CEFR schema, all six CEFR levels, multi-sense coverage, absence of Kindle/Amazon runtime references, durable known-word storage, selected-sense filtering, fixed popup rows, truncation, below-word fallback, collision-layout guards, bounded dictionary caching, and refresh coalescing.

## 10.1 Performance and memory-safety rules

The dictionary connection and prepared statement are opened once per plugin instance and closed in `onCloseDocument`. Lookup results are cached in memory for speed, but the cache is capped at 1,024 surface forms with bounded FIFO eviction. This prevents a long reading session across many unique words from retaining an unbounded number of sense tables. The cache is also cleared when the database closes.

Page hints are stored only for the current visible page and are replaced at the start of every recomputation. Page-update, position-update, and rerender notifications are coalesced into one `nextTick` refresh. A lifecycle generation guard makes an already queued callback harmless if the document closes before the callback executes. The close hook clears hints, closes any open Word Wise dialog, flushes user state, closes SQLite resources, and invalidates the database path.

These controls remove the main source-level unbounded-retention and duplicate-work risks, but they cannot prove that every Android device remains stable under sustained paging. A device stress test should collect KOReader's log and memory information while turning pages continuously for at least 10–15 minutes, with a large book, several thousand unique words, and Word Wise enabled. Watch for a monotonic resident-memory increase after garbage-collection cycles, repeated SQLite errors, stale overlays after document close, and touch or page-turn latency.

Static checks are necessary but not sufficient. Before release, install the plugin on an Android device and test at least:

| Manual test | Expected result |
|---|---|
| Open an EPUB and enable Word Wise | Hints appear without modifying the book. |
| Open a PDF | Plugin remains unavailable or does not attempt unsafe overlay work. |
| Hint at the top edge | Hint moves below the word and remains visible. |
| Several long hints on one line | Hints do not overlap; low-priority hints may be omitted. |
| Tap a long truncated hint | Popup title shows the full definition. |
| Select another sense | The chosen sense appears on future occurrences. |
| Press Know | All senses and inflected forms of the lemma disappear. |
| Restart KOReader | Known words and selected senses remain. |
| Replace the plugin directory | User state remains in the data directory. |
| Tap outside a hint | Normal Android page-turn behavior remains available. |
| Open Dictionary | KOReader's own dictionary popup appears. |

## 11. OTA update contract

The updater is designed for the public fork:

```text
Repository: https://github.com/trigon1998/wordwise.koplugin
Release API: https://api.github.com/repos/trigon1998/wordwise.koplugin/releases/latest
Asset: wordwise.koplugin.zip
```

The updater must use GitHub **Releases**, not the moving `main` branch, as the installation source. A release is an immutable, reviewable version boundary. The updater should perform the following sequence:

```text
User selects Updates → Check for updates
        │
        ▼
Request latest public GitHub release over HTTPS
        │
        ├── parse tag_name / version
        ├── compare with installed version
        └── locate the exact ZIP asset
        │
        ▼
Show versions and release notes; ask before downloading/installing
        │
        ▼
Download to KOReader data/wordwise/ota/
        │
        ▼
Validate ZIP structure and required files
        │
        ▼
Extract beside the active plugin into a temporary directory
        │
        ▼
Atomically swap plugin directories with rollback available
        │
        ▼
Offer to restart KOReader immediately
```

The **Notify on wake when update available** option performs a release-metadata
check only. It never downloads or installs a package in the background, is
opt-in, requires Wi-Fi to already be on, and is throttled to one attempt per
hour for the current KOReader session.

The updater must not silently install an arbitrary branch archive. It should reject a release when:

- the release is a draft or prerelease unless the user explicitly enables prereleases;
- `tag_name` is not a supported semantic version;
- the asset name is not the expected plugin ZIP;
- the ZIP does not contain a single root directory named `wordwise.koplugin`;
- required runtime files (`main.lua`, `_meta.lua`, `wordwise_db.lua`, `wordwise_hint_dialog.lua`, `wordwise_l10n.lua`, `wordwise_ota.lua`, `wordwise_sha256.lua`, or `wordwise.db`) are missing;
- an archive path contains `..`, an absolute path, or another path traversal pattern;
- the download is not HTTPS or returns an unexpected HTTP status; or
- the replacement cannot be completed with a rollback path.

The updater must preserve:

```text
<KOReader data directory>/wordwise/known_words.lua
<KOReader data directory>/wordwise/state.lua
<KOReader data directory>/wordwise/wordwise.db
```

The user database must not be overwritten by an OTA package. The bundled database inside the plugin may change with a release, but a user-supplied database in the data directory always remains authoritative.

A release must include a SHA-256 checksum asset. The updater downloads and verifies both of these exact assets before extracting anything:

```text
wordwise.koplugin.zip
wordwise.koplugin.zip.sha256
```

The updater uses KOReader's `socketutil` timeout-aware table and file sinks rather than raw LuaSocket sinks. GitHub asset downloads use the file-download timeout profile, while release metadata uses the large-content profile. Transient LuaSec errors such as `wantread`, `timeout`, and `sink timeout` are retried a bounded number of times; a permanent failure is reported as a retryable network message rather than exposing a raw transport error. The updater must still be tested on the target Android build because network behavior depends on the bundled LuaSec version and device connection.

The first public OTA release should be created only after the updater itself has been merged and manually tested from a clean installation.

## 12. Release procedure

Use a semantic version tag such as `v0.2.0`. The release checklist is:

1. Update the plugin version constant and user-facing changelog.
2. Rebuild `wordwise.db` from the recorded open sources.
3. Run Lua, Python, database, and static regression checks.
4. Install and test on Android with an EPUB.
5. Create a ZIP whose root is exactly `wordwise.koplugin/`.
6. Generate a SHA-256 checksum for the ZIP.
7. Create a GitHub Release on `trigon1998/wordwise.koplugin` with the tag and both assets.
8. Download the release asset using the OTA menu from an older installation.
9. Confirm that the plugin updates and that `known_words.lua`, `state.lua`, and a user database remain intact.
10. Confirm that the new installation is clean and that no temporary OTA directory is left behind.

Example packaging command:

```sh
git archive --format=zip --prefix=wordwise.koplugin/ \\
  --output=wordwise.koplugin.zip HEAD
sha256sum wordwise.koplugin.zip > wordwise.koplugin.zip.sha256
```

Example GitHub release command:

```sh
gh release create v0.2.0 \\
  wordwise.koplugin.zip \\
  wordwise.koplugin.zip.sha256 \\
  --repo trigon1998/wordwise.koplugin \\
  --title "Word Wise v0.2.0" \\
  --notes-file CHANGELOG.md
```

## 13. Troubleshooting

If the plugin does not appear, verify that the directory is named `wordwise.koplugin`, that `main.lua` is directly inside it, and that it is located under KOReader's `plugins` directory. Restart KOReader completely after replacing a plugin.

If no hints appear, confirm that the document is reflowable, Word Wise is enabled in the current book, and a database exists either at the bundled path or at `<KOReader data directory>/wordwise/wordwise.db`. Use **Known words file** to inspect the data directory path.

If a user database appears to be ignored, verify its schema, close and reopen KOReader, and check that it is not named with an unsupported extension or placed in the plugin directory. The runtime opens SQLite read-only and rejects a schema that has neither `cefr_level` nor the legacy `difficulty` column.

If an OTA update reports that no release exists, the repository may not yet have a GitHub Release. A push to `main` alone is not sufficient for the release-based updater. Create a public release with the expected ZIP asset before testing OTA.

## 14. Data and licensing notes

The project should retain attribution for the upstream plugin and every bundled dictionary source. CEFR profiles and WordNet data may have different licenses and attribution requirements; check the exact license text distributed with each source before redistribution. Kindle/Amazon-derived corpus data must not be included in the public fork without explicit permission and an appropriate redistribution right.

This guide provides engineering guidance, not legal advice. When the upstream repository does not expose a clear license, obtain permission from the original author before distributing modified upstream code or assets.

## References

[1]: https://koreader.rocks/doc/topics/Development_guide.md.html "KOReader Development Guide"
[2]: https://github.com/koreader/koreader/blob/master/frontend/apps/reader/modules/readerhighlight.lua "KOReader ReaderHighlight source and touch precedent"
[3]: https://koreader.rocks/doc/modules/luasettings.html "KOReader LuaSettings documentation"
[4]: https://github.com/openlanguageprofiles/olp-en-cefrj "CEFR-J English vocabulary profiles"
[5]: https://github.com/asxelot/wordwise.koplugin "Upstream Word Wise plugin"
