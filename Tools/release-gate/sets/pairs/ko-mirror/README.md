# ko-mirror (60 clips)

Korean sentences with English words for the 한국어 + English pair, spoken by Yuna. The four mirror
sets hold the same 60 situations of `../mirror-template.jsonl`, each written the way a speaker
of the language who mixes in English would say it, not translated word for word, so their rates
compare:

- m01 to m20: office and developer terms (PR, deadline, deploy, Slack, Jira, sprint, API and
  more)
- m21 to m30: names of people and companies
- m31 to m40: numbers, dates, times and money
- m41 to m50: short replies
- m51 to m60: self corrections, which the reference keeps as spoken

Every clip runs without context, so the set measures the error rate and the recall of the
English words as the model writes them on its own.

`say` writes English words in Hangul as a Korean speaker says them (슬랙, 피알), so Yuna says them
that way. The reference writes them as a user would type them: names of products and companies
and acronyms in Latin letters (Slack, PR, API), common loanwords in Hangul (미팅, 데드라인) and names
of people in Hangul (제니퍼). Each English word is an expected term with its other spellings as
accepted spellings, such as ["Slack", "슬랙"] and ["데드라인", "deadline"]. Where Korean writes a
loanword two ways, both count, such as 릴리스 and 릴리즈 or 푸시 and 푸쉬. Particles follow how the
word is said (Slack으로, API는, ASAP로). Numbers are digits for dates, times, money and percentages
(3시 반, 1,200달러), with 만 for ten thousands (5만 달러), and words for counts with native numbers (세
명). Most numbers list their spelling in words.

No native speaker has read the Korean text of this set yet. Until one has, its references, its
accepted spellings and every result on it are not confirmed by a native reader.
