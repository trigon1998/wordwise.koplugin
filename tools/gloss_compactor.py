#!/usr/bin/env python3
"""Create compact inline glosses while preserving the source definition.

The result is intentionally an extractive phrase, not an invented definition.
Word Wise displays it above the book text and keeps the unmodified definition
in ``full_def`` for the popup.  Keeping this deterministic makes release
databases reproducible and avoids running an AI service on the reader.
"""

import re

MAX_SHORT_CHARS = 72
MAX_SHORT_WORDS = 12

_SPACE_RE = re.compile(r"\s+")
_LEADING_DOMAIN_RE = re.compile(r"^\([^()]{1,48}\)\s*")
_PAREN_RE = re.compile(r"\s*\([^()]{1,160}\)")
_EXAMPLE_RE = re.compile(
    r"\s*(?:,\s*)?(?:for example|for instance|e\.g\.)\b.*$",
    re.IGNORECASE,
)
_DETAIL_BOUNDARY_RE = re.compile(
    r"\b(?:that|which|who|whose|where|when|occurring|characterized|"
    r"consisting|comprising|involving)\b",
    re.IGNORECASE,
)
_TRAILING_STOPWORDS = {
    "a", "an", "the", "of", "to", "for", "with", "and", "or", "in",
    "on", "at", "from", "by", "as", "that", "which", "who", "whose",
    "where", "when", "is", "are", "was", "were", "be", "been",
}


def normalize_gloss(value):
    return _SPACE_RE.sub(" ", (value or "").strip())


def _without_parenthetical_details(text):
    previous = None
    while previous != text:
        previous = text
        text = _PAREN_RE.sub("", text)
    return normalize_gloss(text)


def _bounded_words(text):
    words = text.split()
    kept = []
    for word in words:
        candidate = " ".join(kept + [word])
        if kept and (len(kept) >= MAX_SHORT_WORDS or len(candidate) > MAX_SHORT_CHARS):
            break
        kept.append(word)

    truncated = len(kept) < len(words)
    if truncated:
        while len(kept) > 3 and kept[-1].strip(".,:;!?‘’'\"").lower() in _TRAILING_STOPWORDS:
            kept.pop()
    result = " ".join(kept).rstrip(" -,:;.!?")
    if truncated:
        while kept and len(result) + 1 > MAX_SHORT_CHARS:
            kept.pop()
            result = " ".join(kept).rstrip(" -,:;.!?")
        result += "…"
    return result


def compact_gloss(word, definition):
    """Return a concise, display-safe phrase derived from *definition*.

    Semicolon-delimited explanations, examples, domain labels and parenthetical
    detail are useful in a dictionary popup but make poor inline hints.  Remove
    those first, then enforce a strict word and character budget.  ``word`` is
    accepted for future audited rules and keeps the call site explicit.
    """
    del word
    full = normalize_gloss(definition)
    if not full:
        return ""

    text = _LEADING_DOMAIN_RE.sub("", full)
    text = text.split(";", 1)[0]
    text = _EXAMPLE_RE.sub("", text)
    text = _without_parenthetical_details(text)
    text = re.sub(r"\bas well as\b", "and", text, flags=re.IGNORECASE)
    text = re.sub(r"\beither\s+", "", text, flags=re.IGNORECASE)
    text = re.sub(r"\betc\.?$", "", text, flags=re.IGNORECASE)
    text = re.sub(
        r"^a statement\s+that is made to reply to\s+",
        "a reply to ",
        text,
        flags=re.IGNORECASE,
    )
    text = re.sub(
        r"^the process in which\s+(.+?)\s+(?:is|are)\s+",
        r"\1 ",
        text,
        flags=re.IGNORECASE,
    )
    text = normalize_gloss(text).strip(" -,:;.!?")

    if len(text) > MAX_SHORT_CHARS and ":" in text:
        head = text.split(":", 1)[0].strip()
        if len(head.split()) >= 4:
            text = head

    if len(text) > MAX_SHORT_CHARS:
        boundary = _DETAIL_BOUNDARY_RE.search(text)
        if boundary:
            head = text[:boundary.start()].strip(" -,:;.!?")
            if len(head.split()) >= 4:
                text = head

    # A long comma tail generally adds examples or qualifications.  Keep it in
    # full_def, but omit it from the glanceable inline phrase.
    if len(text) > MAX_SHORT_CHARS and "," in text:
        head = text.split(",", 1)[0].strip()
        if len(head.split()) >= 4:
            text = head

    short = _bounded_words(text).strip(" -,:;.!?")
    return short or _bounded_words(full).strip(" -,:;.!?")


def validate_short_gloss(value):
    return bool(value) and len(value) <= MAX_SHORT_CHARS and len(value.split()) <= MAX_SHORT_WORDS
