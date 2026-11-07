# ja-mirror (60 clips)

Japanese sentences with English words for the 日本語 + English pair, spoken by Kyoko. The four
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

`say` writes English words in katakana as a Japanese speaker says them (スラック, ピーアール), so Kyoko
says them that way. The reference writes them as a user would type them: names of products and
companies and acronyms in Latin letters (Slack, PR, API), common loanwords in katakana (ミーティング,
デプロイ) and names of people in katakana (ジェニファー). Each English word is an expected term with its
other spellings as accepted spellings, such as ["Slack", "スラック"] and ["デプロイ", "deploy"]. Long
vowel variants such as サーバー and サーバ count as the same word. Numbers are digits, with 万 for ten
thousands (5万ドル), and most list their kanji spelling.

No native speaker has read the Japanese text of this set yet. Until one has, its references, its
accepted spellings and every result on it are not confirmed by a native reader.
