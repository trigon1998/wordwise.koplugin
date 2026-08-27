# Word Wise for KOReader Android — Development Guide

## 1. Project scope

This project is an Android-focused fork of [asxelot/wordwise.koplugin](https://github.com/asxelot/wordwise.koplugin). It is a KOReader plugin written in Lua that paints compact vocabulary hints on top of the original document page. It does not rewrite EPUB/PDF content and does not create a second copy of the book.

The fork deliberately removes Kindle/Amazon corpus discovery and conversion. Its bundled dictionary is generated from open vocabulary profiles and open English WordNet data, while the user may provide a separate database under KOReader's data directory. The supported target is KOReader on Android and other KOReader builds with the same reflowable-document APIs.

The main product requirements are:

| Area | Current behavior |
|---|---|
| Document support | Reflowable/crengine documents. PDF and fixed-layout documents are not supported by the overlay engine. |
| Difficulty model | CEFR levels `A1`, `A2`, `B1`, `B2`, `C1`, and `C2`, replacing the upstream 1–5 difficulty setting. |
| Dictionary | Multiple senses per lemma, with CEFR level, part of speech, stable sense key, and data source. |
| Inline display | A bounded single-line gloss with measured-width ellipsis. A long gloss is available in full through the hint popup. |
| Layout | Hint placement above the word when possible, below the word when the top safe inset would be crossed, and collision-aware horizontal placement. |
| Interaction | Tapping a hint opens sense selection, lemma-wide Know/Show, KOReader Dictionary, and Cancel actions. |
| User state | Known words and selected senses are stored outside the plugin directory and survive plugin replacement. |
| Updates | The OTA updater checks GitHub Releases from the fork repository and installs only a validated release asset. |

## 2. Repository layout

```text
wordwise.koplugin/
├── _meta.lua                         # KOReader plugin metadata
├── main.lua                          # lifecycle, menu, overlay, touch, popup, state
├── wordwise_db.lua                   # SQLite lookup and CEFR compatibility layer
├── wordwise_l10n.lua                 # plugin-specific labels and translations
├── wordwise.db                       # bundled CEFR/multi-sense database
├── README.md                         # user-facing overview and installation notes
├── DEVELOPMENT.md                    # this development guide
├── tests/
│   └── test_cefr.py                  # database and static regression checks
└── tools/
    ├── build_cefr_dict.py            # curated gloss importer
    ├── build_cefr_wordnet_dict.py    # CEFR + WordNet multi-sense builder
    ├── open_glosses.tsv              # editable curated gloss source
    ├── cefrj-vocabulary-profile-1.5.csv
    └── octanove-vocabulary-profile-c1c2-1.0.csv
```

The plugin runtime must be installed as a directory named exactly `wordwise.koplugin`. `main.lua` must be directly inside that directory. The bundled database must be adjacent to `main.lua` so the plugin can locate it through its own module path.

## 3. Runtime architecture

`main.lua` owns the plugin lifecycle. During initialization it registers the main-menu item, creates the gloss font, opens the paint-only ReaderView module, registers touch zones, and initializes persistent state. The overlay is intentionally paint-only: the document continues to be rendered by KOReader, while Word Wise draws the hint text and marker on top.

The page flow is:

```text
KOReader opens/reflows page
        │
        ▼
WordWise:computePageHints()
        │
        ├── obtain visible words and screen boxes
        ├── lookup all dictionary senses
        ├── apply CEFR threshold
        ├── skip known lemmas
        ├── select saved sense or first eligible sense
        └── store hint geometry and hit-box data
        │
        ▼
ReaderView overlay calls WordWise:paintHints()
        │
        ├── measure gloss width
        ├── truncate long glosses with `…`
        ├── place above or below the word
        ├── find a non-overlapping horizontal slot
        └── paint text, marker, and optional underline
```

The stability-critical interfaces are KOReader's visible-word enumeration, screen-box calculation, line-spacing adjustment, ReaderView overlay registration, and reflow/page-position callbacks. Changes to dictionary data should not modify these interfaces.

The plugin uses KOReader's documented ReaderView and widget APIs rather than directly modifying the document renderer.[1] The touch behavior follows the same principle as KOReader's highlight interaction: a touch miss is not consumed, allowing normal Android page-turn zones to continue processing the gesture.[2]

## 4. CEFR model and stability

The runtime order is:

```text
A1 < A2 < B1 < B2 < C1 < C2
```

The menu value is a **threshold**. If the selected threshold is `B2`, the plugin permits `B2`, `C1`, and `C2`; it hides `A1` through `B1`. The database stores the normalized level as text and the runtime maps it to an integer rank only for comparison.

The CEFR migration is low risk for page stability because it changes only database lookup and hint filtering. It does not change visible-word traversal, screen-box anchoring, line-spacing hooks, overlay painting, or reflow callbacks. The bundled database uses CEFR as authoritative data. The runtime retains a compatibility path for old upstream databases containing a `difficulty` column, but the five old bands are only an approximate migration and must not be treated as audited CEFR classification.

When adding another level system, keep the following boundaries:

| Concern | Correct location |
|---|---|
| Level normalization and rank | `wordwise_db.lua` |
| Threshold menu values | `main.lua` and `wordwise_l10n.lua` |
| Dataset-to-level mapping | `tools/build_cefr_wordnet_dict.py` |
| Geometry and drawing | `main.lua`, independent of level names |
| User selection persistence | KOReader data directory state file |

A dictionary builder must never invent a CEFR level. A row without an audited mapping is reported and omitted from the generated database.

## 5. Database contract

The canonical schema is:

```sql
CREATE TABLE entries (
    id         INTEGER PRIMARY KEY,
    word       TEXT NOT NULL COLLATE NOCASE,
    short_def  TEXT NOT NULL,
    cefr_level TEXT NOT NULL CHECK(cefr_level IN ('A1','A2','B1','B2','C1','C2')),
    pos        TEXT,
    sense_key  TEXT NOT NULL UNIQUE,
    source     TEXT
);

CREATE INDEX entries_word_idx ON entries(word COLLATE NOCASE);
CREATE INDEX entries_cefr_idx ON entries(cefr_level);
```

Every sense is a separate row. `sense_key` must be deterministic and unique so that saved selections remain stable across page turns. A practical fallback key is the normalized lemma, part of speech, and gloss joined with a non-printing separator; a builder may use a stronger stable identifier when the upstream source provides one.

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

The builder merges the CEFR-J and Octanove profiles, preserves curated project glosses, and adds multiple open WordNet senses for CEFR-mapped lemmas. Curated rows should take precedence when the project has a better short gloss. WordNet definitions should remain attributable to their source and should not be rewritten in a way that obscures provenance.

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

## 7. Hint rendering and collision handling

The inline gloss width is measured using KOReader's rendering metrics, not by counting characters. The current maximum is controlled by `MAX_INLINE_HINT_WIDTH`. If a definition exceeds the available width, `RenderText:truncateTextByWidth` produces a compact string ending in `…`. The full definition remains in the hint object and is shown in the popup title.

The vertical placement algorithm calculates the word box, gloss metrics, top/bottom safe insets, and marker position. It prefers an above-word gloss. If the gloss would cross the top safe inset, the entire unit is moved below the word and the marker points upward.

For horizontal collisions, the renderer:

1. quantizes nearby word boxes into a line band;
2. sorts candidates by line band and CEFR rank, preferring harder words;
3. tries the word-centered position;
4. tries the left and right gaps around already placed hints;
5. checks the minimum horizontal gap; and
6. drops a lower-priority hint only if no legal slot remains.

This is preferable to drawing all hints at their original centered positions. A crowded line may still omit some hints, but it must not render overlapping definitions that are unreadable or visually misleading.

Any future layout change must preserve `hit_box` updates after the final horizontal position is chosen. A painted hint that cannot be tapped is a functional regression.

## 8. Hint interaction and popup

A tap is accepted only when its screen coordinates intersect a rendered hint hit box. A tap outside all hints returns `false`, so KOReader can continue with its normal touch handling.

The popup has three logical areas:

| Area | Behavior |
|---|---|
| Title | Shows the selected word and the full currently displayed definition. |
| Sense list | Shows alternative eligible senses only. The sense already displayed in the title is excluded to avoid duplication. |
| Action row | Horizontal **Know/Show**, **Dictionary**, and **Cancel** buttons. |

A sense row displays the CEFR level, parenthesized part of speech, and gloss. The current KOReader Button widget supports one face and one bold state per button. Therefore, the implementation keeps the row visually prominent and uses the requested `(noun)` / `(verb)` form; true mixed bold/italic spans require a custom row widget and should be implemented separately if exact typography is required.

Selecting an alternative sense stores its stable `sense_key` by lemma and repaints the page. Pressing **Know** stores the lemma as known and hides every sense and inflected occurrence of that lemma. Pressing **Show** removes the lemma from the known-word set. **Dictionary** calls KOReader's standard dictionary lookup for the underlying surface word rather than introducing a second dictionary UI.

## 9. Persistent user state

User state must not be stored inside `wordwise.koplugin`, because a plugin update commonly replaces that directory. The current paths are:

```text
<KOReader data directory>/wordwise/known_words.lua
<KOReader data directory>/wordwise/state.lua
```

`known_words.lua` stores a table under `words`, keyed by normalized lemma. `state.lua` stores selected sense keys under `selected_senses`. The files are opened with KOReader's `LuaSettings` module, which provides `open`, `saveSetting`, and `flush` operations.[3]

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
User selects Check for updates
        │
        ▼
Request latest public GitHub release over HTTPS
        │
        ├── parse tag_name / version
        ├── compare with installed version
        └── locate the exact ZIP asset
        │
        ▼
Ask the user before downloading/installing
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
Tell the user to restart KOReader
```

The updater must not silently install an arbitrary branch archive. It should reject a release when:

- the release is a draft or prerelease unless the user explicitly enables prereleases;
- `tag_name` is not a supported semantic version;
- the asset name is not the expected plugin ZIP;
- the ZIP does not contain a single root directory named `wordwise.koplugin`;
- required files such as `main.lua`, `_meta.lua`, `wordwise_db.lua`, and `wordwise.db` are missing;
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

A release should include a SHA-256 checksum asset or a release-body checksum. If checksum verification is not yet implemented, the UI must describe the updater as a convenience updater rather than a cryptographically verified updater. The preferred long-term design is to publish both:

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
