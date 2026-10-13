# Word Wise v0.2.14 — Offline Word Sense

A streamlined, AI-free way to learn vocabulary as you read in KOReader.

### What's new
- **Subtle wavy underlines:** Difficult words are now marked directly within the original book text instead of showing definitions above each line.
- **Tap to define:** Tap an underlined word to see a short offline WordNet meaning in a nearby bubble. Tap the bubble to open the familiar multi-sense dialog and choose another meaning.
- **Three reading levels:** **Basic** (A2–C2), **Intermediate** (B1–C2), or **Advanced** (C1–C2), using the existing CEFR-labelled dictionary. Older CEFR preferences are migrated without deleting them.
- **Original line spacing restored:** The plugin no longer expands line spacing to make room for definitions. If an earlier Word Wise release changed the book's line spacing, this release restores the previous value when safe.

### Kept unchanged
- Offline WordNet/CEFR database; no AI, account, API key, or network required to look up words.
- Existing word meanings and the ability to select which sense is displayed.
- Know/Show, KOReader Dictionary, selected-sense and known-word persistence.
- Signed-off OTA workflow with GitHub Release ZIP and matching SHA-256 verification.

### Install / update
In KOReader, open **Word Wise → Updates → Check for updates**, review this release, and confirm the update and restart.

After restarting, open a reflowable book and enable **Word Wise → Underline difficult words**. Set **Reading level** to your preferred difficulty.

**Compatibility:** Intended for KOReader on Android with reflowable/crengine books (such as EPUB). Fixed-layout PDF/DjVu underlines are not supported.

**Note:** This release passed the repository's automated Lua/Python checks. Real-device interaction should still be validated on your KOReader build.
