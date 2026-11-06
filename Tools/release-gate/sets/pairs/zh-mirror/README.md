# zh-mirror (60 clips)

Chinese sentences with English words for the 中文 + English pair, spoken by Tingting. The four
mirror sets hold the same 60 situations of `../mirror-template.jsonl`, each written the way a
speaker of the language who mixes in English would say it, not translated word for word, so
their rates compare:

- m01 to m20: office and developer terms (PR, deadline, deploy, Slack, Jira, sprint, API and
  more)
- m21 to m30: names of people and companies
- m31 to m40: numbers, dates, times and money
- m41 to m50: short replies
- m51 to m60: self corrections, which the reference keeps as spoken

Every clip runs without context, so the set measures the error rate and the recall of the
English words as the model writes them on its own.

The sentences are Chinese with English words in Latin letters, like the mixed sentences of the
other Chinese sets. The reference is the text after the number rules, as in zh-numbers-negation:
下午3点半, 15%, 5万美元 and 11月14号 in digits, and 两千个, 两点半 and 两百毫秒 in words, which the rules keep.

The Chinese text of this set was written and reviewed by an AI process, not by a native speaker,
and waits for a native reader. Until one has read it, its references, its accepted spellings and
every result on it rest on AI review only.
