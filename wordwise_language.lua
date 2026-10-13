-- Word Wise dictionary is English-only. Avoid treating Vietnamese (and other
-- non-English) pages as English words such as "con" or "tan".
-- Deliberately conservative: unknown metadata is allowed until page evidence
-- indicates a non-English text. No network, model, or extra book parsing.
local Language = {}

function Language.isEnglishBook(language)
    if type(language) ~= "string" then return nil end
    local tag = language:lower():match("^%s*([%a]+)")
    if not tag or tag == "und" or tag == "unknown" or tag == "mul"
            or tag == "zxx" then return nil end
    return tag == "en" or tag == "eng" or tag == "english"
end

function Language.isAsciiWord(text)
    return type(text) == "string" and not text:find("[\128-\255]")
end

-- In a Vietnamese book the majority of word tokens use non-ASCII diacritics,
-- but an English novel can contain a few foreign names or borrowed terms.
-- Decide only after seeing at least 20 tokens to avoid false positives.
function Language.pageIsNonEnglish(token_count, accented_count)
    return token_count >= 20 and accented_count * 4 >= token_count
end

return Language
