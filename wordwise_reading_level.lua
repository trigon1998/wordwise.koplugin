-- Reader-facing difficulty levels. Keep the existing six-level CEFR database.
local Levels = {
    levels = { "Basic", "Intermediate", "Advanced" },
}
local thresholds = {
    Basic = "A2",
    Intermediate = "B1",
    Advanced = "C1",
}
local legacy = {
    A1 = "Basic", A2 = "Basic",
    B1 = "Intermediate", B2 = "Intermediate",
    C1 = "Advanced", C2 = "Advanced",
}

function Levels.threshold(level)
    return thresholds[level]
end

function Levels.resolve(level, previous_cefr)
    if thresholds[level] then return level end
    return legacy[previous_cefr] or "Intermediate"
end

return Levels
