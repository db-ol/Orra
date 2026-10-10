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
- `kind`: `convert` when some number in the input should become digits (121 cases), `keep`
  when the input must stay exactly as it is (489 cases).
- `input`: a dictation as Qwen3-ASR writes it, with the numbers spelled out.
- `expected`: the text after the number rules.
- `note`: what the case tests.

A wrong conversion is far worse than a missed one, so the rules convert only patterns where a
reader clearly expects digits:

- Readings digit by digit of three digits or more (13800138000, 302, 999), and a year of four
  before 年 (2026年). Two digits stay (三八妇女节, 九零后), except right after a Latin letter
  (CA1831). Counting (一二三四五, 二四六八) and dates of events (五一二, 八一三) stay unless
  a word such as 验证码 or 房间 says it is a code.
- Full dates: a month with its day and 号 or 日 (10月1日), and a month after a year in digits
  (2026年10月). A day without a month (十五号), a month alone (九月份, 二月春风), ranges of
  days (十月一号至七号) and lunar dates (农历八月十五号, 七月七日是七夕) stay.
- Clock times after a time of day such as 下午 or 晚上 (下午3点, 晚上10点半, 下午3点半到4点),
  or with minutes and 分 (3点20分). 三点半, 三点以后, 十点到十点半 and 三点十分 (which can
  mean very) need a time of day. 一点 after a time of day stays when it means a little
  (晚上一点都不冷).
- Percentages (50%, 3.5%), except rough ones and ranges (百分之五十多, 百分之三到五).
- Money: a number with 十, 百, 千, 万 or 亿 before 元, 块 or a currency word (350块, 300美元,
  3.5万元, 3.5亿元, 126万亿元). An amount that needs more places is written whole (13888元),
  and stays in words above 1亿.
- Measurements with a real unit: 公里, 米, 公斤, 斤, 吨, 升, 英寸, 寸, 毫安, 岁, 小时, 分钟,
  秒, 天, 周, 个月, 年 and Latin units such as GB, G and K (42公里, 28岁, 15天, 16GB, 5G).
  度 counts only for a temperature after 零下 or with 摄氏 (零下12度). Decimals before such a
  unit convert (3.5公里). Figures of speech with 年 (一百年都遇不到, 八百年没见了) stay.
- Model numbers glued to a Latin name (M5, iPhone15, RX350), and after a space when a space,
  punctuation, a Latin unit or the end follows (RX 350, iPhone 15 Pro). Versions after a Latin
  name (macOS 15.1, Python 3.12以上). After a person's name (Tom八成, Tom十一回家), before a
  counter (PPT三个小时) and when the time could be a version (Tom三点十五到) the number stays.

Everything else stays in words: single digits (三本书, 五公里), numbers before a plain counter
(二十个人, 十位同学, 三十五页, 十八层, 十八届), 万 and 亿 without money (两万人, 十二万,
三千万), scores (九十五分), ranges (三百到五百元, 三十至四十岁), rough numbers (七八个, 十几个),
ordinals, idioms, poems, names, holidays and book titles. 61 cases that converted under the
earlier, wider rules became keep cases with the note "kept in words since the narrowing", and
n083 keeps 十张 in words while A四 still converts.

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
