# Word Wise v0.2.15 — Dual Display & Microgloss

Choose how Word Wise helps you read, without giving up offline WordNet.

### What's new
- **Two switchable display modes:** **Tap to define** (the v0.2.14 wavy underline and definition bubble) or **Inline hints** (brief definitions above difficult words).
- **Ultra-short Inline hints:** **Micro** displays up to 4 words / 34 characters, and **Short** up to 6 words / 50 characters. Longer extracts show an ellipsis and open their full WordNet meaning on tap.
- **Per-book display preferences:** Select Inline or Tap independently for each book.
- **Safe line spacing:** Inline mode temporarily makes room above words and restores the saved spacing when switching back to Tap mode or disabling Word Wise, unless you changed the spacing yourself.
- **Existing WordNet sense picker:** Tap any visible inline hint or its word to open the full multi-sense dialog, including Know/Show and native KOReader Dictionary.
- **Offline-first:** No AI, server, network connection or API key for dictionary lookups. Microgloss snippets are extracted from the chosen sense, not invented synonyms.

### Unchanged
- Basic (A2+), Intermediate (B1+), Advanced (C1+) reading modes.
- Bundled CEFR/WordNet SQLite dictionary and user dictionary overrides.
- Known words and selected senses stored outside the plugin directory.
- Verified OTA ZIP + SHA-256, archive validation and rollback.

### How to use
1. **Word Wise → Updates → Check for updates**, install v0.2.15 and restart KOReader.
2. Open a reflowable book and enable **Word Wise**.
3. Select **Word Wise → Display mode → Inline hints** or **Tap to define**.
4. When using Inline, optionally choose **Inline detail → Micro / Short**.

**Compatibility:** KOReader on Android, reflowable/crengine books such as EPUB. Fixed-layout PDF/DjVu overlays are not supported.

**Testing:** Automated Lua, definition-popup, inline geometry, offline dictionary, WordNet grouping and OTA regression checks passed on GitHub Actions. Touch behavior on physical e-ink hardware should still be validated.
