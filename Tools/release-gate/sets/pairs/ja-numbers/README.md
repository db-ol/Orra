# ja-numbers (40 sentences, 80 clips)

30 Japanese sentences and 10 with English words, for the 日本語 + English pair, modeled on
zh-numbers-negation: years, dates, amounts of yen with 万 and 億, percentages, times, digit runs
(phone numbers, codes, room numbers), ordinals, versions and negations (じゃなくて, ではなく, ないで, ません).
Each sentence runs twice: `_ctx0` with no context and `_ctx10` with the ten tech terms of
zh-numbers-negation, which do not occur in the sentences, so the gate shows what context does to
numbers.

Orra has no number rules for Japanese yet, so the reference is the text a user would want:
digits for years, dates, times, money, percentages, codes and counts (2026年10月14日, 3時半, 3万5000円,
3回目) and kanji in fixed words (一度). Each number is an expected term, most with their kanji
spelling, and at times other digit spellings, as accepted spellings, such as ["3万5000円",
"三万五千円", "35,000円", "35000円"]. The strict rate then shows how the model writes numbers, and the
lenient rate whether it heard them right. The negation words are expected terms too, so a lost
negation shows even when the error rate barely moves.

`say` writes numbers in kanji, and phone numbers, codes and room numbers in kana as they are
read (ゼロハチゼロ, はちまるろく).

No native speaker has read the Japanese text of this set yet. Until one has, its references, its
accepted spellings and every result on it are not confirmed by a native reader.
