# ko-numbers (40 sentences, 80 clips)

30 Korean sentences and 10 with English words, for the 한국어 + English pair, modeled on
zh-numbers-negation: years, dates, amounts of won with 만 and 억, percentages, times, digit runs
(phone numbers, codes, room numbers), ordinals, versions and negations (아니라, 안, 못, 지 마세요). Each
sentence runs twice: `_ctx0` with no context and `_ctx10` with the ten tech terms of
zh-numbers-negation, which do not occur in the sentences, so the gate shows what context does to
numbers.

Orra has no number rules for Korean yet, so the reference is the text a user would want: digits
for years, dates, times, money, percentages and codes (2026년 10월 14일, 3시 반, 3만 5천 원), with the
unit right after the digits, and words for counts with native numbers and for ages (세 번째, 스물다섯
개, 서른 살). Each number is an expected term, most with their spelling in words as an accepted
spelling, such as ["3만 5천 원", "삼만 오천 원", "35,000원"], and a count in words lists its digits. The
strict rate then shows how the model writes numbers, and the lenient rate whether it heard them
right. The negation words are expected terms too, so a lost negation shows even when the error
rate barely moves.

`say` writes every number in Hangul as it is read, with the native numbers of hours and counts
(세 시, 두 번째) and phone numbers digit by digit (공일공).

The Korean text of this set was written and reviewed by an AI process, not by a native speaker,
and waits for a native reader. Until one has read it, its references, its accepted spellings and
every result on it rest on AI review only.
