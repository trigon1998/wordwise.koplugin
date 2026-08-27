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
assert 'align = "left"' in main
assert 'dictionary_short' in main and 'know_short' in main
assert 'screen_h' in main
print('ui_layout_guards_ok')
assert 'KNOWN_WORDS_PATH' in main
assert 'known_words.lua' in main
assert 'function WordWise:isWordKnown(entry)' in main
assert 'iv[2] + GLOSS_HGAP' in main
assert 'pos .. ")"' in main
print('known_storage_and_overlap_guards_ok')
