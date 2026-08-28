# Word Wise for KOReader

<p align="center">
  <img src="screenshot.png" alt="Word Wise hiển thị gợi ý CEFR trên trang sách" width="720">
</p>

<p align="center">
  <b>Gợi ý từ vựng theo CEFR cho KOReader, tập trung cho Android.</b><br>
  Hiển thị định nghĩa ngắn ngay trên trang sách mà không sửa nội dung sách.
</p>

<p align="center">
  <a href="https://github.com/trigon1998/wordwise.koplugin/releases/latest"><img src="https://img.shields.io/github/v/release/trigon1998/wordwise.koplugin?label=release" alt="Latest release"></a>
  <a href="https://github.com/trigon1998/wordwise.koplugin/releases"><img src="https://img.shields.io/github/downloads/trigon1998/wordwise.koplugin/total?label=downloads" alt="GitHub downloads"></a>
  <a href="https://github.com/trigon1998/wordwise.koplugin/actions/workflows/update-download-stats.yml"><img src="https://github.com/trigon1998/wordwise.koplugin/actions/workflows/update-download-stats.yml/badge.svg" alt="Download stats workflow"></a>
</p>

Word Wise là fork Android-focused của [`asxelot/wordwise.koplugin`](https://github.com/asxelot/wordwise.koplugin). Plugin đặt các gloss ngắn phía trên từ khó, lọc theo **CEFR**, hỗ trợ nhiều sense theo ngữ cảnh, lưu lựa chọn của người dùng bền vững và cập nhật qua GitHub Releases OTA.

> **Phạm vi:** plugin dành cho tài liệu reflowable/crengine trong KOReader. Kindle/Amazon conversion, Kindle corpus và định dạng fixed-layout/PDF không thuộc fork này.

## Tính năng chính

| Tính năng | Mô tả |
| --- | --- |
| **CEFR filtering** | Chọn ngưỡng A1, A2, B1, B2, C1 hoặc C2. Các sense ở mức đã chọn và cao hơn sẽ được xét hiển thị. |
| **Multi-sense hints** | Mỗi từ có thể có nhiều định nghĩa, POS và `sense_key`; người đọc có thể chọn sense phù hợp với ngữ cảnh. |
| **Popup phân trang** | Danh sách sense thay thế được chia thành các trang cố định, không dùng một danh sách cuộn làm mất footer. |
| **Footer cố định** | Ba nút **Know/Show**, **Dictionary** và **Cancel** luôn hiển thị theo hàng ngang. |
| **Typography rõ ràng** | Chỉ tiền tố CEFR in đậm; POS in nghiêng trong ngoặc đơn; định nghĩa dùng font thường. |
| **Trạng thái bền vững** | Danh sách từ đã biết và sense đã chọn nằm ngoài thư mục plugin nên không bị mất khi cập nhật. |
| **OTA qua GitHub Releases** | Menu trong KOReader có thể kiểm tra và cài bản release mới với asset ZIP và checksum chuẩn. |
| **Tối ưu Android** | Lookup cache có giới hạn, refresh được gộp, callback cũ bị chặn theo lifecycle và cây widget popup được giải phóng khi đổi trang. |

## Cài đặt

<details><summary><b>Cài trên Android</b></summary>

1. Mở [trang Releases](https://github.com/trigon1998/wordwise.koplugin/releases) và tải `wordwise.koplugin.zip`.
2. Giải nén thành thư mục có tên chính xác là `wordwise.koplugin`.
3. Chép thư mục đó vào thư mục plugin của KOReader, thường là `koreader/plugins/`.
4. Khởi động lại KOReader, mở một sách reflowable rồi vào **Menu → More tools → Word Wise → Show inline hints**.

</details>

<details><summary><b>Cập nhật OTA</b></summary>

Bản release phải chứa đúng hai asset `wordwise.koplugin.zip` và `wordwise.koplugin.zip.sha256`. Trong KOReader, mở menu Word Wise và chọn **Check for updates**. Plugin kiểm tra GitHub Releases, xác minh asset/checksum và thay thế thư mục plugin sau khi người dùng xác nhận.

OTA chỉ thay đổi mã nguồn trong thư mục plugin. Hai file trạng thái trong thư mục dữ liệu KOReader là `<koreader data dir>/wordwise/known_words.lua` và `<koreader data dir>/wordwise/state.lua`, vì vậy chúng không bị ghi đè khi cập nhật.

</details>

## Cách sử dụng

### Lọc theo CEFR

Mở cấu hình Word Wise và chọn **CEFR threshold**. Với ngưỡng `B2`, plugin xét các sense `B2`, `C1` và `C2`, đồng thời loại các sense `A1` đến `B1`. Các mức hợp lệ là `A1`, `A2`, `B1`, `B2`, `C1` và `C2`.

### Chọn sense theo ngữ cảnh

Chạm vào một hint đang hiển thị để mở popup. Sense hiện tại được đặt trong phần tiêu đề và **không lặp lại** trong danh sách bên dưới. Nếu có nhiều sense thay thế, dùng **Previous** và **Next** để chuyển trang. Mỗi hàng có cùng chiều cao; chạm vào một hàng để lưu sense đó làm lựa chọn ưu tiên cho lemma.

Popup dùng các vùng riêng cho tiêu đề, điều khiển trang, viewport nội dung và footer. Vì vậy **Know/Show**, **Dictionary** và **Cancel** vẫn nằm trên màn hình ở mọi trang, kể cả trang cuối có ít sense hơn.

### Đánh dấu từ đã biết

Chọn **Know** để ẩn toàn bộ lemma, không chỉ sense đang hiển thị. Chọn **Show** trong lần mở sau để khôi phục. Trạng thái này bao phủ các lần xuất hiện và dạng biến cách mà pipeline lookup quy về cùng lemma.

### Mở từ điển KOReader

Chọn **Dictionary** để chuyển từ hiện tại và vùng hộp tương ứng cho trình tra từ điển chuẩn của KOReader.

## Dữ liệu từ điển

Cơ sở dữ liệu bundled sử dụng schema nhiều sense sau đây:

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

Dictionary được build từ CEFR-J, Octanove C1/C2, các gloss đã tuyển chọn và Open English WordNet. Builder chỉ ghi CEFR mapping đã được xác định; dòng không có mapping hợp lệ sẽ bị báo và bỏ qua. Có thể đặt database người dùng tại `<koreader data dir>/wordwise/wordwise.db` để override database bundled.

## Phát triển

<details><summary><b>Build dictionary và chạy kiểm tra</b></summary>

```sh
cd tools
python3 build_cefr_wordnet_dict.py \
  --cefrj cefrj-vocabulary-profile-1.5.csv \
  --octanove octanove-vocabulary-profile-c1c2-1.0.csv \
  --glosses open_glosses.tsv \
  --out ../wordwise.db
```

Các kiểm tra chính của repository gồm Lua syntax validation, Python regression/database tests, kiểm tra schema, loại bỏ Kindle runtime, lifecycle/cache guards, và kiểm tra contract của OTA:

```sh
python3 /home/ubuntu/check_lua_syntax.py
python3 tests/test_cefr.py
python3 -m py_compile tools/*.py
```

</details>

Kiến trúc runtime và quy trình release được ghi trong [`DEVELOPMENT.md`](DEVELOPMENT.md). Mã popup phân trang nằm trong [`wordwise_hint_dialog.lua`](wordwise_hint_dialog.lua), còn logic database, OTA và localization nằm trong các module tương ứng ở thư mục gốc.

## Giới hạn và kiểm thử Android

Các kiểm tra tĩnh không thay thế được kiểm thử trên thiết bị. Trước khi phân phối một bản release, cần kiểm tra trên KOReader Android với một từ có nhiều sense: popup nhiều trang, footer luôn hiển thị, chuyển sang trang sau rồi chọn sense, **Know/Show**, **Dictionary**, **Cancel**, Back/tap ngoài popup và chuyển trang lặp lại để quan sát độ ổn định bộ nhớ.

## Đóng góp

Issue và pull request nên mô tả phiên bản KOReader, thiết bị Android, định dạng sách, CEFR threshold, số lượng sense và các bước tái hiện. Khi thay đổi schema hoặc asset release, hãy cập nhật cả `DEVELOPMENT.md`, regression tests và quy trình OTA.

## Tham khảo

Cấu trúc README này tham khảo cách trình bày giới thiệu ngắn, bảng tính năng, hướng dẫn thu gọn và phần usage của Size Limit [1]. Số lượt tải được lấy từ GitHub Releases API theo asset ZIP cài đặt [2]; file checksum không được tính vào biểu đồ.

## Thống kê lượt tải

Biểu đồ dưới đây thể hiện số lượt tải `wordwise.koplugin.zip` theo từng release và đường tổng lũy kế. Dữ liệu hiện được cập nhật tự động hằng tuần bằng GitHub Actions; có thể chạy workflow thủ công từ tab **Actions** khi cần làm mới ngay.

<p align="center">
  <img src="download-stats.svg" alt="Biểu đồ lượt tải Word Wise theo release" width="920">
</p>

Dữ liệu thô được lưu trong [`download-stats.json`](download-stats.json). GitHub cung cấp bộ đếm theo asset release, không phải lịch sử tải theo từng ngày; vì vậy biểu đồ này đo lượt tải theo release, không diễn giải thành lượt tải hàng ngày [2].

## References

[1]: https://github.com/ai/size-limit "ai/size-limit README"
[2]: https://docs.github.com/en/rest/releases/releases "GitHub REST API — Releases"
[3]: https://github.com/trigon1998/wordwise.koplugin "Word Wise KOReader Android fork"
