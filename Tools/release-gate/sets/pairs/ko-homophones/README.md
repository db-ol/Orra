# ko-homophones (36 clips)

Vocabulary words that sound like common Korean words, for the 한국어 + English pair, as
homophone-distractors does for Chinese and English: Cursor and 커서 (the text cursor, or grown
up), Notion and 노선 (a route), Miro and 미로 (a maze), Excel and 액셀 (the accelerator, said the same
since ㅐ and ㅔ sound alike), Vim and 빔 (a projector), and the given names 서윤 and 서운하다 (to feel
hurt), 예준 and 예전 (former times), 민준 and 민중 (the people), 도현 and 도형 (a figure), 시현 and 시험 (an
exam). Every clip runs with all 10 words as context, the way a user's vocabulary would hold
them. 20 clips say the common word and list the vocabulary word in `forbid_terms`. 16 say the
vocabulary word, some next to the common word, and list it in `expect_terms`. The reference is
the sentence.

`say` writes the vocabulary words as a Korean speaker says them (커서, 빔), and the reference has
the vocabulary's spelling. Notion and Excel also count as right in Hangul (노션, 엑셀), which is not
the common word, so a clip with 노선 forbids both spellings. A clip with 액셀 forbids Excel only,
since 엑셀 is a common misspelling of 액셀 even without a vocabulary, and finding it there would not
show the vocabulary's fault. Cursor, Miro and Vim count only in Latin letters, since their Hangul
is the common word. 프론트엔드 and the standard spelling 프런트엔드 count as the same word.

No native speaker has read the Korean text of this set yet. Until one has, its references, its
accepted spellings and every result on it are not confirmed by a native reader.
