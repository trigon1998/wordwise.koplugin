-- Translations for the Word Wise dictionary-popup button.
--
-- These are plugin-specific strings that are not part of KOReader's shipped
-- translation catalog, so the popup button would otherwise always show in
-- English while every neighbouring button (Close, Search, Add to vocabulary
-- builder, ...) follows the UI language. This table localizes the button in
-- every language KOReader ships an l10n/ for; keys are the KOReader language
-- codes (the value of G_reader_settings "language"). English is intentionally
-- absent -- it is the source text and falls back through gettext.
--
--   know = "I already know this word"  (mark the word as known -> hide its hint)
--   show = "Show Word Wise hint"       (reverse: un-mark a known word)
--
-- "Word Wise" is kept as a Latin product name across scripts, matching how
-- Kindle presents the feature name.
return {
    af_ZA = { know = "Ek ken hierdie woord reeds",        show = "Wys Word Wise-wenk" },
    ar    = { know = "أعرف هذه الكلمة بالفعل",             show = "إظهار تلميح Word Wise" },
    be    = { know = "Я ўжо ведаю гэтае слова",            show = "Паказаць падказку Word Wise" },
    bg_BG = { know = "Вече знам тази дума",                show = "Показване на подсказка Word Wise" },
    bn    = { know = "আমি এই শব্দটি ইতিমধ্যে জানি",          show = "Word Wise ইঙ্গিত দেখান" },
    ca    = { know = "Ja conec aquesta paraula",           show = "Mostra el suggeriment de Word Wise" },
    cs    = { know = "Toto slovo už znám",                 show = "Zobrazit nápovědu Word Wise" },
    cy    = { know = "Rwy'n gwybod y gair hwn eisoes",     show = "Dangos awgrym Word Wise" },
    da    = { know = "Jeg kender allerede dette ord",      show = "Vis Word Wise-tip" },
    de    = { know = "Ich kenne dieses Wort bereits",      show = "Word-Wise-Hinweis anzeigen" },
    el    = { know = "Γνωρίζω ήδη αυτή τη λέξη",           show = "Εμφάνιση υπόδειξης Word Wise" },
    en_GB = { know = "I already know this word",           show = "Show Word Wise hint" },
    eo    = { know = "Mi jam konas ĉi tiun vorton",        show = "Montri Word Wise-sugeston" },
    es    = { know = "Ya conozco esta palabra",            show = "Mostrar sugerencia de Word Wise" },
    et    = { know = "Ma juba tean seda sõna",             show = "Kuva Word Wise'i vihje" },
    eu    = { know = "Hitz hau dagoeneko ezagutzen dut",   show = "Erakutsi Word Wise aholkua" },
    fa    = { know = "من این کلمه را از قبل می‌دانم",        show = "نمایش راهنمای Word Wise" },
    fi    = { know = "Tiedän tämän sanan jo",              show = "Näytä Word Wise -vihje" },
    fr    = { know = "Je connais déjà ce mot",             show = "Afficher l'astuce Word Wise" },
    ga    = { know = "Tá an focal seo ar eolas agam cheana", show = "Taispeáin leid Word Wise" },
    gl    = { know = "Xa coñezo esta palabra",             show = "Mostrar suxestión de Word Wise" },
    he    = { know = "אני כבר יודע את המילה הזאת",          show = "הצג רמז של Word Wise" },
    hi    = { know = "मुझे यह शब्द पहले से पता है",             show = "Word Wise संकेत दिखाएँ" },
    hr    = { know = "Već znam ovu riječ",                 show = "Prikaži Word Wise savjet" },
    hu    = { know = "Már ismerem ezt a szót",             show = "Word Wise tipp megjelenítése" },
    ia    = { know = "Io ja cognosce iste parola",         show = "Monstrar le suggestion Word Wise" },
    id    = { know = "Saya sudah tahu kata ini",           show = "Tampilkan petunjuk Word Wise" },
    ie    = { know = "Yo ja conosse ti parol",             show = "Monstrar li indicie Word Wise" },
    it_IT = { know = "Conosco già questa parola",          show = "Mostra suggerimento Word Wise" },
    ja    = { know = "この単語はもう知っています",            show = "Word Wise のヒントを表示" },
    ka    = { know = "ამ სიტყვას უკვე ვიცნობ",             show = "Word Wise-ის მინიშნების ჩვენება" },
    kab   = { know = "Ssneɣ yakan awal-a",                 show = "Sken talɣut Word Wise" },
    kn    = { know = "ಈ ಪದ ನನಗೆ ಈಗಾಗಲೇ ತಿಳಿದಿದೆ",           show = "Word Wise ಸುಳಿವು ತೋರಿಸಿ" },
    ko_KR = { know = "이 단어를 이미 알고 있습니다",           show = "Word Wise 힌트 표시" },
    lt_LT = { know = "Šį žodį jau žinau",                  show = "Rodyti Word Wise patarimą" },
    lv    = { know = "Es jau zinu šo vārdu",               show = "Rādīt Word Wise padomu" },
    mk    = { know = "Веќе го знам овој збор",              show = "Прикажи совет Word Wise" },
    ms    = { know = "Saya sudah tahu perkataan ini",      show = "Tunjukkan petua Word Wise" },
    nb_NO = { know = "Jeg kan allerede dette ordet",       show = "Vis Word Wise-hint" },
    nl_NL = { know = "Ik ken dit woord al",                show = "Word Wise-hint tonen" },
    ["or"] = { know = "ମୁଁ ଏହି ଶବ୍ଦ ପୂର୍ବରୁ ଜାଣେ",            show = "Word Wise ସୂଚନା ଦେଖାନ୍ତୁ" },
    pl    = { know = "Znam już to słowo",                  show = "Pokaż wskazówkę Word Wise" },
    pt_BR = { know = "Já conheço esta palavra",            show = "Mostrar dica do Word Wise" },
    pt_PT = { know = "Já conheço esta palavra",            show = "Mostrar sugestão do Word Wise" },
    ro    = { know = "Știu deja acest cuvânt",             show = "Afișează indiciul Word Wise" },
    ro_MD = { know = "Știu deja acest cuvânt",             show = "Afișează indiciul Word Wise" },
    ru    = { know = "Я уже знаю это слово",               show = "Показать подсказку Word Wise" },
    si    = { know = "මම මේ වචනය දැනටමත් දනිමි",             show = "Word Wise ඉඟිය පෙන්වන්න" },
    sk    = { know = "Toto slovo už poznám",               show = "Zobraziť pomôcku Word Wise" },
    sl    = { know = "To besedo že poznam",                show = "Pokaži namig Word Wise" },
    sr    = { know = "Већ знам ову реч",                   show = "Прикажи Word Wise савет" },
    sv    = { know = "Jag kan redan det här ordet",        show = "Visa Word Wise-tips" },
    th    = { know = "ฉันรู้จักคำนี้แล้ว",                      show = "แสดงคำใบ้ Word Wise" },
    tr    = { know = "Bu kelimeyi zaten biliyorum",        show = "Word Wise ipucunu göster" },
    uk    = { know = "Я вже знаю це слово",                show = "Показати підказку Word Wise" },
    ur    = { know = "میں یہ لفظ پہلے سے جانتا ہوں",          show = "Word Wise اشارہ دکھائیں" },
    vi    = { know = "Tôi đã biết từ này",                 show = "Hiển thị gợi ý Word Wise" },
    zh_CN = { know = "我已经认识这个词",                     show = "显示 Word Wise 提示" },
    zh_TW = { know = "我已經認識這個詞",                     show = "顯示 Word Wise 提示" },
}
