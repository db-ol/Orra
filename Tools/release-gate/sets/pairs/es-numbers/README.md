# es-numbers (40 sentences, 80 clips)

30 Spanish sentences and 10 with English words, for the Español + English pair, modeled on
zh-numbers-negation: years, dates, amounts of pesos and dollars, percentages, times, digit runs
(phone numbers, codes, room numbers), ordinals, versions and negations (no, nunca, nadie, no
es). Each sentence runs twice: `_ctx0` with no context and `_ctx10` with the ten tech terms of
zh-numbers-negation, which do not occur in the sentences, so the gate shows what context does to
numbers.

Orra has no number rules for Spanish, so the reference is the text a user would want: digits for
years, dates, money, percentages, times and codes, with a comma for thousands and a colon for
minutes (14 de octubre de 2026, 35,000 pesos, 3:30), and words for ordinals, counts of things
(veinticinco bugs) and the bare amounts of no son treinta mil, which mirror the Chinese 不是三万.
Each number is an expected term, most with their spelling in words as an accepted spelling, such
as ["35,000 pesos", "35.000 pesos", "35000 pesos", "35 mil pesos", "treinta y cinco mil pesos"]. A
period for thousands and a comma for decimals, as many Spanish speaking countries write numbers,
count as right too (35.000 pesos, 98,5%). The strict rate then shows how the model writes numbers, and the lenient rate whether it heard them right. The
negation words are expected terms too, so a lost negation shows even when the error rate barely
moves.

`say` writes every number in words as it is read, and the phone number in pairs of digits as
Mexican speakers say it.

The Spanish text of this set was written and reviewed by an AI process, not by a native speaker,
and waits for a native reader. Until one has read it, its references, its accepted spellings and
every result on it rest on AI review only.
