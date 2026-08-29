from pathlib import Path
import sqlite3

ROOT = Path('/home/ubuntu/wordwise-fork')
DB = ROOT / 'wordwise.db'

assert DB.exists(), 'bundled database is missing'
con = sqlite3.connect(DB)
columns = {row[1] for row in con.execute('PRAGMA table_info(entries)')}
assert {'word', 'short_def', 'cefr_level', 'pos', 'sense_key', 'source'} <= columns
assert 'difficulty' not in columns
levels = {row[0] for row in con.execute('SELECT DISTINCT cefr_level FROM entries')}
assert levels <= {'A1', 'A2', 'B1', 'B2', 'C1', 'C2'}
assert len(levels) >= 4
multi = con.execute('SELECT word, COUNT(*) FROM entries GROUP BY word HAVING COUNT(*) > 1 LIMIT 1').fetchone()
assert multi is not None, 'database must contain at least one multi-sense word'
word, count = multi
assert count > 1
print('schema_ok')
print('levels', sorted(levels))
print('multi_sense_example', word, count)
print('entry_count', con.execute('SELECT COUNT(*) FROM entries').fetchone()[0])
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
assert 'align = "left"' in dialog
assert 'pos' in dialog and '"): "' in dialog
assert 'dictionary_short' in dialog and 'know_short' in dialog
assert 'WordWiseHintDialog' in main
assert 'pcall(WordWiseHintDialog.new' not in main
assert 'if not (self:isEnabled() and ges and self.ui and self.ui.view)' in main
assert 'ReaderReady consistently' not in main
assert 'self.owner:setSelectedSense(selected)' in dialog
assert 'local is_current = current_key and entry.sense_key == current_key' in dialog
assert 'selected = current_key and entry.sense_key == current_key or false' in dialog
assert 'bold = self.selected' in dialog
assert 'local label_prev, label_next = "‹", "›"' in dialog
assert 'Page %1 of %2' in (ROOT / 'wordwise_l10n.lua').read_text()
assert 'font_bold = false' in dialog
assert 'height = self.row_height' in dialog
print('popup_selection_style_and_navigation_guards_ok')
ota = (ROOT / 'wordwise_ota.lua').read_text()
assert 'trigon1998' in ota and 'wordwise.koplugin' in ota
assert 'releases/latest' in ota and 'wordwise.koplugin.zip' in ota
assert 'https://' in ota and 'safe_archive_path' in ota
assert 'known_words.lua' in (ROOT / 'DEVELOPMENT.md').read_text()
print('ota_contract_guards_ok')
db_lua = (ROOT / 'wordwise_db.lua').read_text()
assert 'local CACHE_LIMIT = 1024' in db_lua
assert 'function WordWiseDB:_cacheInsert' in db_lua
assert 'self.cache, self.cache_order = {}, {}' in db_lua
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
assert 'local width_cache = h._render_cache' in main
assert 'h._render_cache = width_cache' in main
assert 'local hit_box = it.h.hit_box or {}' in main
print('render_allocation_guards_ok')
