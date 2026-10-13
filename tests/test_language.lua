-- Ensure English-only dictionary never marks a Vietnamese document as English.
local root = (... and ... ~= "") and ... or "."
package.path = root .. "/?.lua;" .. package.path
local Lang = require("wordwise_language")

assert(Lang.isEnglishBook("en") == true)
assert(Lang.isEnglishBook("en-US") == true)
assert(Lang.isEnglishBook("ENG") == true)
assert(Lang.isEnglishBook("English") == true)
assert(Lang.isEnglishBook("vi") == false)
assert(Lang.isEnglishBook("vi-VN") == false)
assert(Lang.isEnglishBook("Vietnamese") == false)
assert(Lang.isEnglishBook("fr") == false)
assert(Lang.isEnglishBook(nil) == nil)
assert(Lang.isEnglishBook("und") == nil)

assert(Lang.isAsciiWord("con"))
assert(Lang.isAsciiWord("bewildered"))
assert(not Lang.isAsciiWord("tàn"))
assert(not Lang.isAsciiWord("một"))
assert(not Lang.isAsciiWord("café"))
assert(not Lang.isAsciiWord("trở"))
assert(Lang.pageIsNonEnglish(60, 20))
assert(Lang.pageIsNonEnglish(60, 15))
assert(not Lang.pageIsNonEnglish(60, 14))
assert(not Lang.pageIsNonEnglish(18, 18))
assert(not Lang.pageIsNonEnglish(60, 3))
print("english_language_guard_and_vietnamese_page_heuristic_ok")
