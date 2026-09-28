from pathlib import Path
import sqlite3
import sys

ROOT = Path(__file__).resolve().parents[1]
DB = ROOT / 'wordwise.db'
sys.path.insert(0, str(ROOT / 'tools'))

from gloss_compactor import compact_gloss

assert compact_gloss('ambassador', 'a diplomat of the highest rank; accredited as representative from one country to another') == 'a diplomat of the highest rank'
assert compact_gloss('answer', 'a statement that is made to reply to a question or request or criticism or accusation') == 'a reply to a question or request or criticism or accusation'
assert compact_gloss('carbon', 'an abundant nonmetallic tetravalent element occurring in three allotropic forms: amorphous carbon, graphite, and diamond') == 'an abundant nonmetallic tetravalent element'
assert len(compact_gloss('airport', 'an airfield equipped with control tower and hangars as well as accommodations for passengers and cargo')) <= 72

assert DB.exists(), 'bundled database is missing'
con = sqlite3.connect(DB)
columns = {row[1] for row in con.execute('PRAGMA table_info(entries)')}
assert {'word', 'short_def', 'full_def', 'cefr_level', 'pos', 'sense_key', 'source'} <= columns
assert 'difficulty' not in columns
levels = {row[0] for row in con.execute('SELECT DISTINCT cefr_level FROM entries')}
assert levels <= {'A1', 'A2', 'B1', 'B2', 'C1', 'C2'}
assert len(levels) >= 4
multi = con.execute('SELECT word, COUNT(*) FROM entries GROUP BY word HAVING COUNT(*) > 1 LIMIT 1').fetchone()
assert multi is not None, 'database must contain at least one multi-sense word'
word, count = multi
assert count > 1
max_short_chars = con.execute('SELECT MAX(LENGTH(short_def)) FROM entries').fetchone()[0]
assert max_short_chars <= 72
shortened = con.execute('SELECT COUNT(*) FROM entries WHERE short_def <> full_def').fetchone()[0]
assert shortened > 1000
for short_def, in con.execute('SELECT short_def FROM entries'):
    assert len(short_def.split()) <= 12, short_def
print('schema_ok')
print('levels', sorted(levels))
print('multi_sense_example', word, count)
print('entry_count', con.execute('SELECT COUNT(*) FROM entries').fetchone()[0])
print('concise_glosses', shortened, 'max_chars', max_short_chars)
con.close()

for path in [ROOT / 'main.lua', ROOT / 'wordwise_db.lua', ROOT / 'README.md']:
    text = path.read_text()
    assert ('WordWise' + 'Kindle') not in text
    assert ('kll.' + 'en.en') not in text
print('no_runtime_kind le_references_ok'.replace(' ', ''))

main = (ROOT / 'main.lua').read_text()
assert 'truncateTextByWidth' in main
assert 'below_baseline' in main and 'below_top' in main
assert 'hit_box' in main
assert 'screen_h' in main
print('ui_layout_guards_ok')
assert 'KNOWN_WORDS_PATH' in main
assert 'known_words.lua' in main
assert 'function WordWise:isWordKnown(entry)' in main
assert 'iv[2] + GLOSS_HGAP' in main
print('known_storage_and_overlap_guards_ok')
dialog = (ROOT / 'wordwise_hint_dialog.lua').read_text()
assert 'ButtonDialog:extend' in dialog
assert 'ButtonDialog.init(self)' in dialog
assert 'align = "left"' in dialog
assert 'pos' in dialog and 'entry.pos' in dialog
assert 'dictionary_short' in dialog and 'know_short' in dialog
assert 'WordWiseHintDialog' in main
assert 'pcall(WordWiseHintDialog.new' not in main
assert 'if not (self:isEnabled() and ges and self.ui and self.ui.view)' in main
assert 'ReaderReady consistently' not in main
assert 'owner:setSelectedSense(entry)' in dialog
assert dialog.index('self:closeDialog()\n    owner:setSelectedSense(entry)') > 0
assert 'callback = self:_selectCallback(entry)' in dialog
assert 'entry.sense_key == self.current_key' in dialog
assert 'font_bold = is_current' in dialog
assert 'font_face = "infofont"' in dialog
assert 'font_size = self.popup_font_size' in dialog
assert 'text_font_bold' not in dialog
assert 'text_font_face' not in dialog
assert 'text_font_size' not in dialog
assert 'reader_font.font_size' in dialog
assert 'MAX_POPUP_SENSES = 8' in dialog
assert 'icon_prev, icon_next = "chevron.left", "chevron.right"' in dialog
assert 'Page %1 of %2' in (ROOT / 'wordwise_l10n.lua').read_text()
assert 'font_bold = false' in dialog
assert 'self.movable.ges_events = {}' in dialog
assert 'self.movable.unmovable = true' in dialog
assert 'height = self.sense_row_height' in dialog
assert 'self.popup_font_size + 20' in dialog
assert 'self.current_entry.full_gloss or self.current_entry.gloss' in dialog
print('popup_selection_style_and_navigation_guards_ok')
assert 'function WordWise:chooseHintEntry(entries, selected_key, cefr_rank)' in main
assert 'local word_qualifies = false' in main
assert 'if not word_qualifies then return nil end' in main
assert 'candidate.sense_key == selected_key\n                    and not self:isSenseKnown(candidate)' in main
assert 'candidate.sense_key == selected_key and candidate.cefr_rank >= cefr_rank' not in main
assert 'self:chooseHintEntry(entries, selected_key, cefr_rank)' in main
print('manual_sense_selection_guards_ok')
ota = (ROOT / 'wordwise_ota.lua').read_text()
meta = (ROOT / '_meta.lua').read_text()
assert 'trigon1998' in ota and 'wordwise.koplugin' in ota
assert 'releases/latest' in ota and 'wordwise.koplugin.zip' in ota
assert 'https://' in ota and 'safe_archive_path' in ota
assert 'component == "." or component == ".."' in ota
assert 'wordwise.koplugin.zip.sha256' not in ota  # constructed from asset_name
assert 'checksum_url' in ota and 'SHA256.digest_file' in ota
assert 'MAX_EXTRACTED_SIZE' in ota and 'MAX_ARCHIVE_ENTRIES' in ota
assert 'wordwise_hint_dialog.lua' in ota and 'wordwise_l10n.lua' in ota
assert 'archive version does not match release tag' in ota
assert 'current_version = "0.2.13"' in ota
assert 'version = "0.2.13"' in meta
assert 'known_words.lua' in (ROOT / 'DEVELOPMENT.md').read_text()
print('ota_contract_guards_ok')
db_lua = (ROOT / 'wordwise_db.lua').read_text()
assert 'local CACHE_LIMIT = 1024' in db_lua
assert 'function WordWiseDB:_cacheInsert' in db_lua
assert 'full_gloss = full_gloss or gloss' in db_lua
assert 'self.cache, self.cache_order = {}, {}' in db_lua
assert 'IRREGULAR' in db_lua
assert 'Restored-e forms must precede the bare stem' in db_lua
assert 'legacy_sense_penalty' in db_lua
assert 'function WordWise:scheduleHintRefresh()' in main
assert 'self._hint_refresh_scheduled' in main
assert 'self._lifecycle_generation' in main
assert 'self._hint_dialog = nil' in main
assert 'self._db_path = nil' in main
print('memory_and_refresh_guards_ok')
assert 'socketutil.table_sink' in ota
assert 'socketutil.file_sink' in ota
assert 'attempts < 4' in ota
assert 'transport_error == "wantread"' in ota
assert 'FILE_BLOCK_TIMEOUT' in ota and 'FILE_TOTAL_TIMEOUT' in ota
assert 'otaErrorText' in main
assert 'update_network_retry' in (ROOT / 'wordwise_l10n.lua').read_text()
print('ota_android_retry_guards_ok')
assert 'function WordWise:dismissOTAStatus()' in main
assert 'function WordWise:showOTAStatus(text)' in main
assert 'self:showOTAStatus(self:tr("checking_update"))' in main
assert 'self:dismissOTAStatus()' in main
print('ota_status_cleanup_guards_ok')
assert 'function WordWise:showOTARelease(release)' in main
assert 'require("ui/widget/textviewer")' in main
assert 'function WordWise:backgroundUpdateCheck()' in main
assert 'Notification:notify' in main
assert 'UIManager:restartKOReader()' in main
assert 'function OTA:fetch_latest_cached()' in ota
assert 'BACKGROUND_CHECK_INTERVAL = 60 * 60' in ota
assert 'Notify on wake when update available' in (ROOT / 'wordwise_l10n.lua').read_text()
print('ota_release_notes_wake_notification_and_restart_guards_ok')
assert 'local width_cache = h._render_cache' in main
assert 'h._render_cache = width_cache' in main
assert 'local hit_box = it.h.hit_box or {}' in main
print('render_allocation_guards_ok')

assert 'local function lookupKey(text)' in main
assert 'text:match("^%s*[^%a]*([%a]+)[^%a]*%s*$")' in main
assert 'word:gsub("[^%a]", "")' not in main
assert 'function WordWise:getDBCandidates()' in main
assert 'table.sort(names)' in main
assert 'db_fallback' in main
assert 'wordwise_previous_line_spacing' in main
assert 'wordwise_applied_line_spacing' in main
assert 'ds:delSetting(previous_key)' in main
print('normalization_db_fallback_and_spacing_guards_ok')

builder = (ROOT / 'tools' / 'build_cefr_wordnet_dict.py').read_text()
assert 'candidates = defaultdict(dict)' in builder
assert 'available = max(0, max_senses_per_word - curated_counts[word])' in builder
assert 'sense_usage_count' in builder
assert 'specialized_sense_penalty' in builder
assert 'sense_rank INTEGER NOT NULL' in builder
print('wordnet_grouping_and_ranking_guards_ok')
