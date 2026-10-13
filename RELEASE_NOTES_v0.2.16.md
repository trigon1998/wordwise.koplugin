# Word Wise v0.2.16 — Inline Readability & Language Guard

A maintenance release correcting two problems seen with v0.2.15 Inline hints on Android.

### Fixed
- **Micro and Short look different again.** Removed the fixed 138-pixel rendering cap that truncated both settings to almost the same first couple of words. Micro (up to 4 words) and Short (up to 6 words) now have separate, screen-proportional width budgets.
- **No invisible vocabulary words.** If multiple Inline labels cannot fit side-by-side without overlapping, the remaining eligible words receive subtle wavy underlines. Tap those words for the complete WordNet sense picker.
- **Better micro-definitions.** Leading articles such as "a" and "an" are dropped from above-word snippets where appropriate, leaving more room for informative words.
- **No English glosses scattered through Vietnamese books.** Honors KOReader language metadata and excludes known non-English books. When the book has no language metadata, Word Wise detects heavily accented text and suppresses likely non-English pages. Non-ASCII word tokens are never partially misread as English lemmas.

### Preserved
- Per-book Inline / Tap-to-define mode switching.
- Global Micro / Short and Basic / Intermediate / Advanced settings.
- Existing WordNet senses, saved choices, and known-word data.
- Automatic OTA updates with SHA-256, archive validation and rollback.

### Important

**Word Wise is an English-learning aid.** If you open a Vietnamese-language book, there should now be **no English WordNet annotations**. To use Word Wise, open an English ebook with correct English-language metadata.

**Inline limitation:** Dense rows cannot fit every hint above each word without overlapping book text. Remaining words receive a tap-enabled underline as a fallback.

### Update

**KOReader → Word Wise → Updates → Check for updates**, install **v0.2.16**, and restart.

Automated Lua, layout, language, dictionary and OTA checks passed. Please validate on your actual KOReader device; especially the width of Micro and Short labels and taps on underlined fallback words.
