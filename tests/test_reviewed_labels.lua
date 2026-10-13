local root = (... and ... ~= "") and ... or "."
package.path = root .. "/?.lua;" .. package.path
local Labels = require("wordwise_sense_labels")
local path = os.tmpname()
local fh = assert(io.open(path, "wb"))
fh:write("# sense_key\tword\tpos\tsource\tkind\tlabel\tstatus\n")
fh:write("1234567890abcdef\tperfunctory\tadjective\toewn:2024:ewn-01234567-a\tsynonym\tcursory\tapproved\n")
fh:write("fedcba0987654321\tperfunctory\tadjective\toewn:2024:ewn-01234567-a\tsynonym\tsuperficial\tPENDING\n")
fh:write("789456123000abcd\tperfunctory\tadjective\toewn:2025:ewn-01234567-a\tsynonym\tcasual\tapproved\n")
fh:close()
local registry = Labels.load(path)
os.remove(path)
assert(registry.accepted == 1)
local item = {
    sense_key = "1234567890abcdef",
    word = "perfunctory", pos = "adjective",
    source = "oewn:2024:ewn-01234567-a",
}
assert(registry:get(item) == "cursory")
item.source = "oewn:2024:ewn-99999999-a"
assert(registry:get(item) == nil)
item.source = "oewn:2024:ewn-01234567-a"
item.pos = "noun"
assert(registry:get(item) == nil)
item.pos = "adjective"
item.sense_key = "fedcba0987654321"
assert(registry:get(item) == nil, "Unapproved labels must not be displayed")
assert(Labels.load("/no/such/wordwise_sense_labels.tsv").accepted == 0)
print("reviewed_label_sense_identity_and_safe_fallback_ok")
