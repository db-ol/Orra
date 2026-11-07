# ja-homophones (36 clips)

Vocabulary words that sound like common Japanese words, for the 日本語 + English pair, as
homophone-distractors does for Chinese and English: Cursor and カーソル (the text cursor), Rust and
ラスト (last), Ruby and ルビー (the gem) or ルビ (reading aids over kanji), LINE and ライン (a line), Slack
and スラックス (slacks), Linear and リニア (the maglev train), and the surnames 佐藤 and 砂糖 (sugar), 近藤
and 今度 (next time), 工藤 and 駆動 (drive), 東海林 and 障子 (a paper screen). Every clip runs with all 10
words as context, the way a user's vocabulary would hold them. 18 clips say the common word and
list the vocabulary word in `forbid_terms`. 18 say the vocabulary word, some next to the common
word, and list it in `expect_terms`. The reference is the sentence.

`say` writes the vocabulary words as a Japanese speaker says them (ラスト for Rust, しょうじ for 東海林),
and the reference has the vocabulary's spelling. Slack also counts as right in katakana (スラック),
which is not a common word. The other English words count only in Latin letters, since their
katakana is the common word. Long vowel variants of other words count as the same word, such as
パーサー and パーサ.

No native speaker has read the Japanese text of this set yet. Until one has, its references, its
accepted spellings and every result on it are not confirmed by a native reader.
