# Rewrite evaluation set

Text cases for the steps that run after transcription: removing fillers, applying spoken
self corrections, and translating a dictation. Nothing here is part of the app build, and
nothing here is a recording.

## The cases

`cases.jsonl` has 178 cases, one JSON object per line:

- `id`: a short name such as `fz01`.
- `category`: see below.
- `input`: a dictation written the way Qwen3-ASR 1.7B writes it, with full width
  punctuation in Chinese and a space between Chinese and an English word.
- `cleanup`: the text Orra should paste after cleanup.
- `translate_en` and `translate_zh`: the text Orra should paste when the target language
  is English or Simplified Chinese. For input already in the target language this is the
  cleanup.
- `rules`: true when rules that remove only fillers that are certainly empty (呃, um, uh,
  嗯 that is not a reply, 啊 or 哦 opening a clause) should produce `cleanup` on their own,
  false when it takes a model.
- `notes`: what the case tests.

The categories:

| Category | Cases | What it tests |
| --- | --- | --- |
| filler_zh, filler_en, filler_mixed | 25, 15, 15 | Hesitation fillers in Chinese, English and mixed speech |
| particle_keep | 20 | Particles and words that look like fillers and carry meaning: 好啊, 是吧, 对呀, 看看, 谢谢, 那个 as a demonstrative, uh-huh |
| correction_zh, correction_en, correction_mixed | 15, 10, 10 | Spoken self corrections of times, numbers, names and places, restarts, scratch that, 删掉这句, 撤回 |
| control_keep | 28 | Text that must stay as it is: 不是 and 不对 as plain words, both values meant (是三点，不是四点), a bare 嗯嗯, questions and requests that must not be answered, injection lines |
| translate | 40 | Chinese, English and mixed input, each into both targets |

The cases are synthetic. They were written by hand to look like Qwen3-ASR output and were
not transcribed from anyone's speech. The expected outputs are the ground truth, written
by hand too. A cleanup removes fillers and applies clear self corrections. It does not
reword, does not answer a question and does not carry out a request.

## Numbers

`numbers.jsonl` has 610 cases for writing spoken Chinese numbers as digits, one JSON
object per line:

- `id`: n001 and up.
- `kind`: `convert` when some number in the input should become digits (175 cases), `keep`
  when the input must stay exactly as it is (344 cases).
- `input`: a dictation as Qwen3-ASR writes it, with the numbers spelled out.
- `expected`: the text after the number rules.
- `note`: what the case tests.

The conventions, chosen to convert only where a reader clearly expects digits:

- Readings digit by digit of three digits or more become digits (13800138000, 302, 999).
  A year needs four (2026年). Two digits stay (三八妇女节, 九零后), except right after a
  Latin letter (CA1831). Counting by one or two (一二三四五, 五四三二一, 二四六八), weekdays
  (一三五) and dates of events (五一二, 八一三) stay unless a word such as 验证码 or 房间 says it is a code.
- Numbers with 十, 百, 千, 万 or 亿 become digits before a unit or counter. 万 and 亿 stay
  as units the way Chinese news writes them (2万人, 3.5亿元, 3.5万元 for 三万五千元), and
  so does 万亿 (126万亿元). An amount that needs more places is written whole (13888元),
  and stays in words above 1亿. Without a unit, a number with 万 or 亿 converts only at the
  end of a phrase or before a word such as 的 or 左右, so 十万大山 and 九万里 stay. A word
  that starts with a unit character is not a unit (十五元宵节, 二十年轻人, 十一期间).
- The start of a range converts with its end (300到500元, 10点到10点半), and the end
  stays when the start does (三到五月份, 百分之三到五). A digit after 度 or 块 joins the
  number (36.5度, 99块9), and other amounts in two parts stay whole (三十块零五毛,
  一分三十秒). A price for one stays (三千一个月). Rough pairs (十块八块), figures of
  speech (说了一百遍, 一百个不愿意, 十二分满意, 一百个胆子) and the tens place (十位) stay.
- A single digit before a counter stays in words (三本书, 两次, 一号线, 五块钱), unless it
  is part of a date, a time, a percentage, a decimal or a model name.
- Times after a time of day, or with 半, 钟, minutes or 以后 (下午3点, 3点20分, 3点半).
  三点五分 could be a time or a score and stays, but 下午3点5分 is a time. 一点 after a
  time of day stays when it means a little (晚上一点都不冷), and 十分 before an adjective
  is very (三点十分重要).
- A month becomes digits only in a date, before a day or 份 or after a year (10月1日,
  9月份), so 二月春风 and 十月稻田 stay. Lunar dates (农历八月十五号, 腊月二十三号) and
  dates of lunar festivals (七月七日是七夕) stay.
- Ranges and rough numbers (七八个, 十几个, 二十多个, 三十来岁, 上千人), ordinals
  (第十五届), set phrases, idioms, poems, names, holidays (双十一, 九一八) and book titles
  stay.

The cases merge two sets written by hand. One duplicate and 47 cases that repeated another
with other words around the same number were dropped, and 19 were added for conventions
neither set covered, such as 三点一刻, 十二万三千, 三百分之一 and a range of times. The two
sets agreed on every convention. Review added 103 cases, n299 to n401, for idioms, poems
and titles, words that start with a unit character, lunar dates, counting, ranges and units
the first rules missed. A second review added 118 cases, n402 to n519, for prices for one
(三千一个月), the tens place, intensifiers and hyperbole (一百二十个放心, 八百遍, 一百个胆子),
sayings, titles and plenum names, numbers after a person's name, 一点 as a little before
半年 or 整理, rough percentages, amounts in two parts (三十块零五毛) and both ends of a
range. A third review added 91 cases, n520 to n610, for 一点 as a little before a price or a
duration (便宜一点五十块), words that end in a digit before 十 (唯一十八岁, 高三十个班, 张三十八岁),
sayings and song titles, scores, phone numbers in groups and ranges whose ends differ.

OrraTests/NumberRulesTests.swift runs every case, so Orra/NumberRules.swift gets all of
them while the tests pass.

## Scoring

Python 3.8 or later, standard library only. Run from this folder:

    python3 score.py cases.jsonl predictions.jsonl
    python3 score.py cases.jsonl predictions.jsonl --task translate_en --show
    python3 score.py cases.jsonl --baseline

A predictions file has one line per case, `{"id": "fz01", "output": "..."}`. `--task`
picks the expected field (`cleanup` by default), `--category` limits the categories,
`--show` prints every mismatch, and `--baseline` scores the unchanged input.

Per category the script reports:

- exact: the output equals the expected text after trimming and folding runs of spaces.
- loose: equal after removing punctuation and spaces and folding case.
- numbers: the share of cases whose numbers (digits, Chinese numerals and English number
  words) all appear in the output.
- too long: outputs more than twice as long as expected, which usually means the model
  answered or carried out the dictation.
- For cleanup, the cases in control_keep and particle_keep that changed, and the share of
  their words or Chinese characters that went missing.

## Results

The filler rules alone, Orra/FillerRules.swift as of this commit, exact match on cleanup.
OrraTests/FillerRulesTests.swift checks every case marked `rules` in the filler, particle
and control categories, so these numbers hold while the tests pass.

| Category | Exact |
| --- | --- |
| filler_zh | 20 of 25 |
| filler_en | 11 of 15 |
| filler_mixed | 12 of 15 |
| particle_keep | 20 of 20 |
| control_keep | 28 of 28 |
| translate (cleanup only) | 40 of 40 |
| correction_* | 0 of 35, rules do not apply corrections |

The misses are fillers that only a model can judge (那个, like, 就是说, a repeated
然后) and fillers between two commas that only mark a pause, where the rules keep one
comma ("I was, wondering").
