# Word Wise for KOReader Android — Tài liệu phát triển

## 1. Mục đích và phạm vi

Word Wise là plugin Lua cho [KOReader](https://github.com/koreader/koreader), được phát triển từ [`asxelot/wordwise.koplugin`](https://github.com/asxelot/wordwise.koplugin) và tối ưu cho KOReader trên Android. Plugin đọc các từ đang hiển thị trên trang, tra cứu gloss ngắn trong SQLite, rồi vẽ gợi ý lên trên bản render gốc của tài liệu.

Plugin **không sửa EPUB**, không tạo bản sao sách và không thay đổi nội dung tài liệu. Fork này loại bỏ Kindle/Amazon corpus, Kindle conversion và các công cụ build phụ thuộc vào dữ liệu Amazon. Dữ liệu bundled được xây dựng từ các nguồn CEFR/WordNet mở và các gloss đã tuyển chọn trong repository.

| Phạm vi | Quyết định hiện tại |
| --- | --- |
| Nền tảng chính | KOReader Android |
| Loại tài liệu | Reflowable/crengine; cần API từ, hộp chữ và reflow của KOReader |
| Không hỗ trợ | PDF, fixed-layout và tài liệu không cung cấp screen-box cho từ |
| Mô hình độ khó | CEFR `A1`, `A2`, `B1`, `B2`, `C1`, `C2` |
| Dictionary | Nhiều sense cho mỗi lemma, kèm POS, CEFR, `sense_key` và nguồn |
| Trạng thái người dùng | Lưu ngoài thư mục plugin để tồn tại qua OTA/update |
| Cập nhật | GitHub Releases với ZIP cài đặt và checksum SHA-256 |
| Phiên bản hiện tại | `0.2.6` |

Các API nền tảng của plugin nên tiếp tục tuân theo kiến trúc widget, ReaderView và reflow của KOReader thay vì sửa trực tiếp document renderer.[1]

## 2. Nguyên tắc kiến trúc

Có bốn nguyên tắc cần giữ khi mở rộng project.

Thứ nhất, **overlay là paint-only**. KOReader tiếp tục render sách; Word Wise chỉ vẽ text, marker và đường gạch chân lên vùng hiển thị hiện tại. Không được đưa gloss vào EPUB, PDF hoặc DOM nội bộ của tài liệu.

Thứ hai, **lookup và layout phải độc lập**. Database chỉ trả về sense và metadata. Logic CEFR, de-inflection và cache nằm trong `wordwise_db.lua`; logic đo kích thước, đặt vị trí, hitbox và paint nằm trong `main.lua`.

Thứ ba, **trạng thái người dùng nằm ngoài plugin**. OTA có thể thay toàn bộ thư mục `wordwise.koplugin`, nhưng không được xóa `known_words.lua`, `state.lua` hoặc database người dùng trong thư mục dữ liệu KOReader.

Thứ tư, **mọi bộ nhớ có thể tăng theo thời gian phải có giới hạn hoặc lifecycle rõ ràng**. Cache lookup bị giới hạn 1.024 surface forms, hint chỉ giữ cho trang hiện tại, callback chờ được bảo vệ bằng lifecycle generation, và cây widget popup cũ phải được giải phóng trước khi tạo trang mới.

## 3. Cấu trúc repository

```text
wordwise.koplugin/
├── _meta.lua                         # metadata và version của plugin
├── main.lua                          # lifecycle, menu, overlay, touch và state
├── wordwise_db.lua                   # SQLite lookup, CEFR và compatibility layer
├── wordwise_hint_dialog.lua          # popup sense phân trang, footer cố định
├── wordwise_l10n.lua                 # nhãn plugin và bản dịch
├── wordwise_ota.lua                  # kiểm tra/tải/cài GitHub Release
├── wordwise.db                       # database CEFR/multi-sense bundled
├── README.md                         # tài liệu người dùng
├── DEVELOPMENT.md                    # tài liệu kỹ thuật này
├── download-stats.json               # dữ liệu lượt tải ZIP theo release
├── download-stats.svg                # biểu đồ lượt tải được nhúng trong README
├── .github/workflows/
│   └── update-download-stats.yml     # workflow cập nhật biểu đồ hằng tuần
├── tests/
│   └── test_cefr.py                  # regression, schema và static guards
└── tools/
    ├── build_cefr_dict.py            # importer gloss đã tuyển chọn
    ├── build_cefr_wordnet_dict.py    # builder CEFR + WordNet multi-sense
    ├── update_download_chart.py      # lấy GitHub API và sinh biểu đồ
    ├── open_glosses.tsv              # nguồn gloss có thể chỉnh sửa
    ├── cefrj-vocabulary-profile-1.5.csv
    └── octanove-vocabulary-profile-c1c2-1.0.csv
```

Khi đóng gói để cài, thư mục gốc trong archive phải có tên chính xác là `wordwise.koplugin/`, và `main.lua` phải nằm trực tiếp bên trong thư mục đó. `wordwise.db` bundled phải nằm cạnh `main.lua`.

## 4. Luồng runtime

`main.lua` sở hữu lifecycle của plugin. Khi khởi tạo, module đăng ký menu, font gloss, ReaderView paint module, vùng touch và các file state. Chỉ tài liệu được `isSupportedDocument()` xác nhận mới được xử lý.

Luồng tính hint cho một trang như sau:

```text
KOReader mở/reflow trang
        │
        ▼
WordWise:computePageHints()
        │
        ├── lấy các từ đang nhìn thấy và screen box
        ├── tra lookupAll() cho từng surface word
        ├── áp dụng CEFR threshold
        ├── bỏ qua lemma đã biết
        ├── chọn sense đã lưu hoặc sense đủ điều kiện đầu tiên
        └── lưu gloss, box, hitbox và dữ liệu đo
        │
        ▼
ReaderView gọi WordWise:paintHints()
        │
        ├── đo chiều rộng glyph bằng RenderText
        ├── cắt gloss dài với `…`
        ├── đặt gloss phía trên hoặc dưới từ
        ├── tìm khoảng ngang không chồng lấn
        └── vẽ text, marker và underline tùy cấu hình
```

Các điểm hook nhạy cảm nhất là visible-word enumeration, screen-box calculation, interline spacing, ReaderView overlay và các callback sau khi reflow/page turn. Thay đổi database hoặc popup không được làm thay đổi những interface này nếu không có kiểm thử Android tương ứng.

## 5. Mô hình CEFR

Thứ tự CEFR được chuẩn hóa như sau:

```text
A1 < A2 < B1 < B2 < C1 < C2
```

Giá trị trong menu là **ngưỡng**, không phải một level duy nhất. Nếu ngưỡng là `B2`, runtime cho phép `B2`, `C1` và `C2`, đồng thời loại `A1` đến `B1`. Text CEFR được lưu trong database; runtime chỉ ánh xạ sang rank số để so sánh.

| Trách nhiệm | Module đúng |
| --- | --- |
| Chuẩn hóa level và so sánh rank | `wordwise_db.lua` |
| Menu threshold và nhãn | `main.lua`, `wordwise_l10n.lua` |
| Mapping dataset sang CEFR | `tools/build_cefr_wordnet_dict.py` |
| Đo kích thước và vẽ | `main.lua` |
| Lưu lựa chọn người dùng | `state.lua` trong data directory |

Builder **không được tự suy đoán CEFR**. Gloss không có mapping đã kiểm tra phải được báo và loại khỏi database. Compatibility path cho schema cũ có `difficulty` chỉ là ánh xạ xấp xỉ, không được xem như CEFR đã kiểm định.

Việc chuyển từ difficulty 1–5 sang CEFR có rủi ro thấp đối với độ ổn định page layout vì nó chỉ tác động đến lookup và filtering. Không được để tên level ảnh hưởng đến screen-box traversal, line spacing, overlay paint hoặc reflow callback.

## 6. Database contract

Schema canonical là:

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

Mỗi sense là một row riêng. `sense_key` phải ổn định và duy nhất để lựa chọn đã lưu không bị thay đổi qua các lần page turn. Nếu nguồn không cung cấp ID bền vững, builder có thể tạo key từ lemma đã normalize, POS và gloss bằng separator không in được.

| API | Mục đích |
| --- | --- |
| `lookup(word)` | Trả sense đầu tiên, dùng cho caller đơn giản hoặc compatibility |
| `lookupAll(word)` | Trả mọi sense đủ điều kiện cho filtering và popup |

Lookup hỗ trợ de-inflection thận trọng cho một số dạng plural, `-ed`, `-ing` và `-ly`. Không mở rộng heuristic tùy tiện vì stem sai có thể hiển thị gloss của lemma khác.

Database người dùng đặt tại:

```text
<KOReader data directory>/wordwise/wordwise.db
```

sẽ được ưu tiên hơn database bundled. Runtime mở SQLite ở chế độ read-only. Database nên được build offline và thay thế như một file hoàn chỉnh; plugin không được mutate database bundled khi đang chạy.

## 7. Build dictionary

Builder chính kết hợp CEFR-J, Octanove C1/C2, curated glosses và các sense từ Open English WordNet:

```sh
cd tools
python3 build_cefr_wordnet_dict.py \
  --cefrj cefrj-vocabulary-profile-1.5.csv \
  --octanove octanove-vocabulary-profile-c1c2-1.0.csv \
  --glosses open_glosses.tsv \
  --out ../wordwise.db
```

`open_glosses.tsv` được ưu tiên khi project có gloss ngắn và phù hợp hơn. Sense từ WordNet phải giữ nguồn gốc có thể truy nguyên. Không thêm Kindle/Amazon-derived data vào public build.

Trước khi commit database mới, cần kiểm tra số row, phân bổ CEFR và độ phủ multi-sense:

```sh
python3 - <<'PY'
import sqlite3
con = sqlite3.connect('wordwise.db')
print(con.execute('select count(*) from entries').fetchone()[0])
print(con.execute('select cefr_level, count(*) from entries group by cefr_level order by cefr_level').fetchall())
print(con.execute('select word, count(*) from entries group by word having count(*) > 1 order by count(*) desc limit 10').fetchall())
PY
```

Các file raw source, license và attribution cần được giữ trong repository để developer khác có thể tái tạo database.

## 8. Inline rendering và collision handling

Gloss inline được đo bằng rendering metrics của KOReader, không cắt theo số ký tự. `MAX_INLINE_HINT_WIDTH` giới hạn chiều rộng. Nếu gloss vượt giới hạn, `RenderText:truncateTextByWidth` tạo chuỗi ngắn kết thúc bằng `…`; bản đầy đủ vẫn nằm trong hint object và được hiển thị trong popup.

Thuật toán vertical placement ưu tiên gloss phía trên từ. Nếu top safe inset bị vượt, toàn bộ hint unit chuyển xuống dưới từ và marker đổi hướng lên. Không được chỉ di chuyển text mà bỏ marker hoặc hitbox ở vị trí cũ.

Để xử lý collision ngang, renderer nhóm box theo line band, ưu tiên từ CEFR cao hơn, thử vị trí chính giữa rồi thử các khoảng trái/phải hợp lệ. Hint có độ ưu tiên thấp có thể bị bỏ nếu không còn khoảng hợp pháp, nhưng không được vẽ các định nghĩa chồng lên nhau.

Sau khi chọn vị trí cuối cùng, `hit_box` phải được cập nhật theo đúng geometry mới. Hint nhìn thấy nhưng không thể chạm là regression chức năng.

## 9. Popup sense phân trang

Popup nằm trong `wordwise_hint_dialog.lua` và không dùng một `ButtonDialog` cuộn toàn bộ. Cấu trúc popup gồm bốn vùng độc lập:

| Vùng | Hành vi |
| --- | --- |
| Header | Hiển thị word và definition đầy đủ của sense hiện tại |
| Page controls | Previous, page indicator và Next |
| Content viewport | Các sense thay thế của trang hiện tại, chiều cao cố định |
| Footer | Know/Show, Dictionary và Cancel trong một hàng ngang cố định |

Sense hiện tại được lọc bằng `sense_key` và không xuất hiện lần nữa trong alternatives. Các sense đã biết cũng bị loại khỏi danh sách. Nếu có nhiều alternatives, `page_size` được tính từ ngân sách chiều cao của dialog sau khi trừ header, separator, page controls, footer, border và padding. Viewport vẫn giữ chiều cao cố định ở trang cuối để footer không nhảy vị trí.

Mỗi row là `SenseRow`, có chiều cao bằng nhau và là một `InputContainer` có vùng tap riêng. Typography được tạo từ các widget con độc lập:

```text
[A1] (noun): regular definition
```

CEFR dùng `bold = true`, POS dùng face `NotoSans-Italic.ttf` và nằm trong ngoặc đơn, còn definition dùng `infofont` regular. Không dùng một Button label duy nhất cho row vì Button chuẩn không biểu diễn được đúng các face hỗn hợp này. Popup dùng face `infofont` mặc định của KOReader cho title, sense rows, page controls và action buttons; không lấy cỡ chữ document làm kích thước popup.

Khi chuyển trang, dialog gọi `self:free()` để giải phóng đệ quy cây widget hiện tại, xóa root references rồi build lại content, page controls và root container. Đây là pattern tương tự reinit của KOReader `ButtonDialog`/`ConfirmBox` và tránh orphaned TextWidget, SenseRow, ButtonTable hoặc tài nguyên native.

Popup là container tĩnh, không dùng `MovableContainer` và không đăng ký hold/pan/swipe để di chuyển hoặc đổi alpha. Vì vậy hold và swipe trong popup được cố ý bỏ qua; popup giữ nguyên vị trí và opacity, còn swipe bắt đầu ngoài popup vẫn để ReaderView xử lý.

Page controls dùng arrow labels theo convention của KOReader khi API có sẵn, với Previous ở trái, indicator ở giữa và Next ở phải. Indicator là nút no-op; Previous/Next bị disable đúng ở đầu/cuối danh sách.

Dialog có các hành vi đóng sau:

| Tình huống | Kết quả |
| --- | --- |
| Cancel | Đóng popup |
| Back/Home | Đóng popup qua `onClose()` |
| Tap ngoài popup | Đóng popup và không truyền gesture tiếp |
| Tap ngoài hint trước khi popup mở | Không consume, giữ page-turn behavior |
| Chọn SenseRow | Lưu `sense_key`, repaint và đóng popup |
| Dictionary | Đóng popup rồi gọi dictionary chuẩn của KOReader |

`closeDialog()` có guard để owner reference chỉ được xóa một lần. Các hàm `onShow`, `onCloseWidget` và `onTapClose` phải chỉ dùng `self.dialog_frame.dimen` khi widget còn hợp lệ.

## 10. Persistent user state

Không lưu state bên trong `wordwise.koplugin`, vì OTA sẽ thay thế thư mục này. Các file hiện tại là:

```text
<KOReader data directory>/wordwise/known_words.lua
<KOReader data directory>/wordwise/state.lua
```

`known_words.lua` chứa table `words`, được index theo lemma đã normalize. `state.lua` chứa `selected_senses`. Runtime sử dụng `LuaSettings` để open, save setting và flush các file state.[2]

| Hành động | Tác động |
| --- | --- |
| Know | Đánh dấu toàn bộ lemma đã biết, ẩn mọi sense và occurrence quy về lemma đó |
| Show | Xóa lemma khỏi known-word set |
| Chọn sense | Lưu `sense_key` theo lemma |
| OTA/plugin replacement | Không đụng đến hai file state hoặc database người dùng |

Nếu schema state thay đổi, thêm version và migration một lần. Không âm thầm xóa state cũ:

```lua
state_version = 2
known_words = { ... }
selected_senses = { ... }
```

Menu **Known words file** phải tiếp tục hiển thị path thực tế trên thiết bị để hỗ trợ backup và troubleshooting.

## 11. Hiệu năng và memory safety

Các quy tắc dưới đây là bắt buộc khi sửa runtime:

| Khu vực | Quy tắc |
| --- | --- |
| SQLite | Một connection và prepared statement cho mỗi plugin/document lifecycle; phải đóng khi document đóng |
| Lookup cache | FIFO bounded ở 1.024 surface forms; phải clear khi database đóng |
| Page hints | Chỉ giữ hints của trang hiện tại; thay thế ở đầu mỗi lần recompute |
| Refresh | Gộp PageUpdate, PosUpdate và rerender vào một `nextTick` |
| Callback cũ | Dùng lifecycle generation để callback sau khi document đóng trở thành no-op |
| Popup page turn | `self:free()` cây widget cũ trước khi build trang mới |
| Close document | Clear hints, đóng dialog, flush state, đóng SQLite và invalidate DB path |
| Render allocation | Tái sử dụng measurement/hitbox data trong current-page hints, tránh tạo table tạm không cần thiết |

Các biện pháp này loại bỏ các nguồn retain không giới hạn rõ ràng ở cấp source, nhưng **không thể chứng minh tuyệt đối** rằng mọi thiết bị Android đều ổn định trong mọi điều kiện. Cần stress test thực tế với sách dài, nhiều nghìn từ khác nhau và chuyển trang liên tục tối thiểu 10–15 phút.

## 12. OTA update contract

OTA chỉ lấy public GitHub Release của repository:

```text
Repository: https://github.com/trigon1998/wordwise.koplugin
Latest API: https://api.github.com/repos/trigon1998/wordwise.koplugin/releases/latest
ZIP asset: wordwise.koplugin.zip
Checksum: wordwise.koplugin.zip.sha256
```

Luồng cài đặt là:

```text
User chọn Check for updates
        │
        ▼
GET latest GitHub Release qua HTTPS
        │
        ├── đọc tag/version
        ├── so sánh với version đang cài
        └── tìm đúng ZIP asset
        │
        ▼
Hỏi xác nhận trước khi tải/cài
        │
        ▼
Tải vào data/wordwise/ota/
        │
        ▼
Kiểm tra root directory và required files
        │
        ▼
Extract vào staging directory
        │
        ▼
Swap plugin directory có backup/rollback
        │
        ▼
Thông báo restart KOReader
```

Updater phải từ chối release nếu tag không phải semantic version, asset sai tên, archive thiếu file bắt buộc, archive có path traversal, response không qua HTTPS hoặc swap không thể rollback. Không cài branch archive đang thay đổi.

Asset phải có root duy nhất là `wordwise.koplugin/` và tối thiểu gồm `main.lua`, `_meta.lua`, `wordwise_db.lua`, `wordwise_hint_dialog.lua` và `wordwise.db`. Dữ liệu người dùng dưới `<KOReader data directory>/wordwise/` không được nằm trong ZIP và không được bị updater xóa.

Network code sử dụng timeout-aware sinks của KOReader `socketutil`. Các lỗi tạm thời như `wantread`, timeout và sink timeout được retry hữu hạn; lỗi vĩnh viễn phải hiện thông báo có thể thử lại thay vì raw transport error. Hành vi LuaSec vẫn cần được kiểm tra trên bản KOReader Android đích.

## 13. Thống kê lượt tải và biểu đồ README

README hiển thị `download-stats.svg` ở cuối trang. Script `tools/update_download_chart.py` gọi GitHub Releases API, bỏ qua draft/prerelease và chỉ đếm asset có tên chính xác `wordwise.koplugin.zip`. File `.sha256` không được tính vì nó là asset xác minh, không phải gói cài đặt.

Script ghi hai output ổn định:

```text
download-stats.json   # release, published_at, downloads, cumulative_downloads
download-stats.svg    # biểu đồ cột theo release và đường lũy kế
```

Chạy thủ công:

```sh
python3 tools/update_download_chart.py
```

Workflow `.github/workflows/update-download-stats.yml` chạy mỗi tuần và có `workflow_dispatch`. Workflow chỉ commit khi JSON/SVG thay đổi, vì vậy không tạo commit mới nếu số lượt tải không đổi. GitHub Releases API cung cấp bộ đếm theo asset, không phải lịch sử tải theo từng ngày; biểu đồ vì thế mô tả downloads per release và cumulative total.[3]

Khi thêm release mới, không sửa tay số trong SVG. Hãy chạy script sau khi asset đã được publish để lấy số liệu thật từ GitHub.

## 14. Thiết lập môi trường phát triển

Project được chạy thực tế bằng LuaJIT bên trong KOReader. Nếu workstation không có LuaJIT/KOReader đầy đủ, repository dùng `luaparser` để kiểm tra cú pháp ở mức parser:

```sh
sudo pip3 install luaparser
```

Chạy từ root repository:

```sh
python3 /home/ubuntu/check_lua_syntax.py
python3 tests/test_cefr.py
python3 -m py_compile tools/*.py
python3 tools/update_download_chart.py
```

`check_lua_syntax.py` phải bao gồm mọi Lua module có thể load ở runtime, đặc biệt là `wordwise_hint_dialog.lua`. Không dùng Python compile như bằng chứng rằng Lua runtime behavior đã đúng.

Regression suite hiện kiểm tra schema và sáu CEFR levels, multi-sense coverage, không có Kindle/Amazon runtime reference, known-word persistence, selected-sense exclusion, pagination, fixed footer, equal row height, CEFR bold, POS italic, regular definition, truncation, collision guards, bounded cache, refresh coalescing, OTA contract và cleanup status.

## 15. Ma trận kiểm thử Android

Static tests không thay thế manual test trên thiết bị. Mỗi release nên kiểm tra ít nhất các trường hợp sau:

| Kiểm thử | Kết quả mong đợi |
| --- | --- |
| Mở EPUB và bật Word Wise | Hint xuất hiện, nội dung sách không bị sửa |
| Mở PDF/fixed-layout | Plugin không chạy overlay unsafe hoặc giữ trạng thái unavailable |
| Hint sát mép trên | Hint chuyển xuống dưới và vẫn nhìn thấy đầy đủ |
| Nhiều hint dài trên một dòng | Không chồng lấn; hint ưu tiên thấp có thể bị bỏ |
| Chạm hint bị truncate | Popup hiển thị definition đầy đủ |
| Từ có nhiều sense | Popup có Previous/Next và footer luôn nhìn thấy |
| Trang cuối ít sense hơn | Viewport/footer không nhảy sai vị trí |
| Chọn sense ở trang sau | Sense đã chọn xuất hiện ở occurrence tiếp theo |
| Kiểm tra typography | CEFR chỉ bold, POS italic trong ngoặc, definition regular |
| Nhấn Know | Toàn bộ lemma và dạng biến cách liên quan biến mất |
| Nhấn Show | Hint của lemma có thể được khôi phục |
| Nhấn Dictionary | Dictionary chuẩn của KOReader mở đúng surface word |
| Nhấn Cancel/Back/tap ngoài | Popup đóng đúng một lần |
| Restart KOReader | Known words và selected senses vẫn còn |
| Thay thư mục plugin | User state và database người dùng vẫn còn |
| Chuyển trang liên tục 10–15 phút | Không có memory growth bất thường, stale overlay hoặc latency tăng dần |
| OTA từ bản cũ | ZIP được xác minh, plugin thay thế, state không bị mất |

Khi stress test, nên lưu KOReader log, version thiết bị, version KOReader, loại sách, CEFR threshold và số lượng unique words. Cần chú ý resident-memory có tăng đơn điệu sau các chu kỳ GC hay không, SQLite errors, stale callback sau document close và page-turn latency.

## 16. Troubleshooting

Nếu plugin không xuất hiện, kiểm tra tên thư mục có đúng `wordwise.koplugin`, `main.lua` có nằm trực tiếp bên trong và thư mục có nằm trong `koreader/plugins/` hay không. Sau khi thay plugin, restart KOReader hoàn toàn.

Nếu không có hint, xác nhận tài liệu là reflowable, Word Wise đã bật cho book hiện tại và database tồn tại tại bundled path hoặc `<KOReader data directory>/wordwise/wordwise.db`. Dùng menu **Known words file** để tìm data directory.

Nếu user database bị bỏ qua, kiểm tra schema, tên file và vị trí. Runtime chấp nhận schema CEFR có `cefr_level` hoặc compatibility schema cũ có `difficulty`, nhưng SQLite được mở read-only và lỗi schema sẽ không tự được sửa.

Nếu popup có vấn đề, kiểm tra `wordwise_hint_dialog.lua`, đặc biệt là `page_size`, `content_viewport`, `action_table`, `onTapClose`, `onClose`, `self:free()` trước rebuild và dirty region dùng `self.movable.dimen` hiện tại. Không đưa trở lại `ButtonDialog` scroll toàn bộ nếu yêu cầu footer cố định vẫn còn hiệu lực.

Nếu OTA báo không có release, push lên `main` là chưa đủ. Phải có GitHub Release public với tag semantic version và đúng hai asset `wordwise.koplugin.zip` cùng `wordwise.koplugin.zip.sha256`.

Nếu biểu đồ chưa cập nhật, chạy workflow **Update download statistics** thủ công hoặc chạy `python3 tools/update_download_chart.py` rồi kiểm tra `download-stats.json`. Chỉ asset ZIP cài đặt được tính vào số liệu.

## 17. Quy trình release

Một release mới nên được thực hiện theo thứ tự sau:

1. Cập nhật version trong `_meta.lua` và `wordwise_ota.lua`.
2. Cập nhật README/developer documentation và release notes nếu hành vi người dùng thay đổi.
3. Rebuild `wordwise.db` từ các source đã ghi nhận nếu database thay đổi.
4. Chạy Lua parser, Python regression, Python compile và `git diff --check`.
5. Kiểm thử Android thực tế, bao gồm popup nhiều trang, footer, OTA và memory stress.
6. Commit và push branch chính.
7. Tạo ZIP với root chính xác `wordwise.koplugin/`.
8. Tạo checksum SHA-256.
9. Tạo GitHub Release với đúng tag và hai asset OTA.
10. Test OTA từ một bản cài cũ và xác nhận `known_words.lua`, `state.lua` cùng user database không bị thay đổi.
11. Chạy workflow cập nhật thống kê sau khi release đã public.

Ví dụ đóng gói:

```sh
git archive --format=zip --prefix=wordwise.koplugin/ \
  --output=wordwise.koplugin.zip HEAD
sha256sum wordwise.koplugin.zip > wordwise.koplugin.zip.sha256
```

Ví dụ tạo release:

```sh
gh release create v0.2.6 \
  wordwise.koplugin.zip \
  wordwise.koplugin.zip.sha256 \
  --repo trigon1998/wordwise.koplugin \
  --title "Word Wise v0.2.6" \
  --notes-file RELEASE_NOTES.md
```

## 18. License và attribution

Repository phải giữ attribution cho upstream plugin và từng nguồn dictionary. CEFR-J, Octanove và WordNet có thể có điều khoản khác nhau; trước khi redistribute cần kiểm tra license text đi kèm từng source. Không đưa Kindle/Amazon corpus vào public fork nếu chưa có quyền phân phối phù hợp.

Tài liệu này là hướng dẫn kỹ thuật, không phải tư vấn pháp lý. Vì upstream có thể không công bố license rõ ràng, nên cần làm rõ quyền sử dụng với tác giả upstream trước khi phân phối code hoặc asset sửa đổi.

## References

[1]: https://koreader.rocks/doc/topics/Development_guide.md.html "KOReader Development Guide"
[2]: https://koreader.rocks/doc/modules/luasettings.html "KOReader LuaSettings documentation"
[3]: https://docs.github.com/en/rest/releases/releases "GitHub REST API — Releases"
[4]: https://github.com/asxelot/wordwise.koplugin "Upstream Word Wise plugin"
[5]: https://github.com/openlanguageprofiles/olp-en-cefrj "CEFR-J vocabulary profiles"
