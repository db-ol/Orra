# Writes sentences.jsonl: the synthetic sentences of the built-in terms evaluation.
# Each row: id, lang (en, zh or mixed), voice (a macOS `say` voice), reference (the
# expected text), say (what `say` reads when it differs, so it sounds as people say it),
# terms (the built-in terms the sentence holds, empty for a control) and control.
import json
from pathlib import Path

EN = ["Samantha", "Daniel", "Reed (English (US))", "Flo (English (US))"]
ZH = ["Tingting", "Eddy (Chinese (China mainland))", "Flo (Chinese (China mainland))", "Reed (Chinese (China mainland))"]

# (reference, terms, spoken form or None)
english = [
    ("I asked ChatGPT to summarize the meeting notes.", ["ChatGPT"], None),
    ("Claude Code fixed the failing test in two minutes.", ["Claude Code"], None),
    ("We switched the team from Copilot to Cursor last month.", ["Copilot", "Cursor"], None),
    ("DeepSeek released a new reasoning model this week.", ["DeepSeek"], None),
    ("Gemini can read the whole PDF at once.", ["Gemini"], None),
    ("Can you deploy the preview on Vercel and connect it to Supabase?", ["Vercel", "Supabase"], None),
    ("The cluster runs on Kubernetes with three nodes.", ["Kubernetes"], None),
    ("Rewrite the training loop in PyTorch.", ["PyTorch"], None),
    ("The front end is written in TypeScript with React.", ["TypeScript", "React"], None),
    ("Open the project in Xcode and preview the SwiftUI view.", ["Xcode", "SwiftUI"], None),
    ("Download the weights from Hugging Face.", ["Hugging Face"], None),
    ("The server speaks MCP so any agent can call it.", ["MCP"], None),
    ("Every LLM in the benchmark failed the same question.", ["LLM"], None),
    ("Post the design in Figma and share the link in Slack.", ["Figma", "Slack"], None),
    ("I keep my reading list in Notion.", ["Notion"], None),
    ("Push the branch to GitHub before lunch.", ["GitHub"], None),
    ("My new MacBook Pro runs the model in under a second.", ["MacBook Pro"], None),
    ("Test it on an iPhone and an iPad before the release.", ["iPhone", "iPad"], None),
    ("Anthropic and OpenAI both shipped new models in the same week.", ["Anthropic", "OpenAI"], None),
    ("Run Qwen3.5 locally with Ollama.", ["Qwen3.5", "Ollama"], "Run Kwen three point five locally with Oh llama."),
    ("GPT-5 wrote the first draft and I edited it.", ["GPT-5"], "G P T five wrote the first draft and I edited it."),
    ("We store sessions in Redis and orders in PostgreSQL.", ["Redis", "PostgreSQL"], "We store sessions in Redis and orders in Postgres Q L."),
    ("The demo runs on Docker and Cloudflare.", ["Docker", "Cloudflare"], None),
    ("I watched a talk about LangChain on YouTube.", ["LangChain", "YouTube"], None),
]
chinese = [
    ("我用豆包写了一份周报。", ["豆包"], None),
    ("通义千问的新版本支持更长的上下文。", ["通义千问"], None),
    ("文心一言今天更新了。", ["文心一言"], None),
    ("这家店在小红书上很火。", ["小红书"], None),
    ("她在抖音上发了一个视频。", ["抖音"], None),
    ("会议链接我发到飞书群里了。", ["飞书"], None),
    ("请假要在钉钉上提交申请。", ["钉钉"], None),
    ("你加我微信吧。", ["微信"], None),
    ("这个功能要等鸿蒙的新版本。", ["鸿蒙"], None),
    ("我在哔哩哔哩上看了那场发布会。", ["哔哩哔哩"], None),
    ("我们用腾讯会议开周会。", ["腾讯会议"], None),
    ("他在知乎上写了一篇长文。", ["知乎"], None),
    ("模型放在阿里云上，接口走火山引擎。", ["阿里云", "火山引擎"], None),
    ("月之暗面和智谱都发布了新模型。", ["月之暗面", "智谱"], None),
    ("我用支付宝付过款了。", ["支付宝"], None),
    ("这个视频是用剪映剪的。", ["剪映"], None),
    ("外卖我在美团上点了。", ["美团"], None),
    ("我在拼多多和京东上比了价格。", ["拼多多", "京东"], None),
    ("可灵和即梦都能生成视频。", ["可灵", "即梦"], None),
    ("腾讯元宝可以直接搜索公众号文章。", ["腾讯元宝"], None),
]
mixed = [
    ("我昨天用Claude写了一个脚本。", ["Claude"], None),
    ("你试试Cursor的新功能。", ["Cursor"], None),
    ("这个任务交给DeepSeek跑一下。", ["DeepSeek"], None),
    ("我们把服务部署到Kubernetes上了。", ["Kubernetes"], None),
    ("数据处理用PyTorch重写一下。", ["PyTorch"], None),
    ("前端统一改成TypeScript。", ["TypeScript"], None),
    ("这个页面在Figma里还没改完。", ["Figma"], None),
    ("会议纪要我放在Notion里了。", ["Notion"], None),
    ("代码已经推到GitHub上了。", ["GitHub"], None),
    ("我的MacBook装不了这个版本的Xcode。", ["MacBook", "Xcode"], None),
    ("新买的iPhone拍照很清楚。", ["iPhone"], None),
    ("模型可以从Hugging Face或者ModelScope下载。", ["Hugging Face", "ModelScope"], None),
    ("这个工具支持MCP协议。", ["MCP"], None),
    ("大家都在讨论LLM的推理成本。", ["LLM"], None),
    ("Gemini和ChatGPT哪个更好用？", ["Gemini", "ChatGPT"], None),
    ("用Copilot写单元测试很快。", ["Copilot"], None),
    ("Qwen3.5的小模型在本地跑得很快。", ["Qwen3.5"], "Kwen三点五的小模型在本地跑得很快。"),
    ("我们在Slack上讨论过这个问题。", ["Slack"], None),
    ("后端放在Supabase上，前端放在Vercel上。", ["Supabase", "Vercel"], None),
    ("用SwiftUI写界面比以前快多了。", ["SwiftUI"], None),
]
controls_en = [
    "Move the cursor to the end of the line.",
    "There is some slack in the schedule this week.",
    "I have a notion that the train will be late.",
    "She was born under the sign of Gemini.",
    "The cat clawed the sofa again.",
    "We had dinner at a small restaurant near the river.",
    "Please send me the report before Friday.",
    "The weather was cold and the roads were empty.",
]
controls_zh = [
    "今天下午三点开会。",
    "我把文件放在桌子上了。",
    "这本书我已经看完了。",
    "明天早上记得带伞。",
    "我们晚上去吃火锅吧。",
    "这个问题我们下周再讨论。",
]
controls_mixed = [
    "这个PPT明天要交。",
    "你把这个bug修一下。",
    "我们下午开个meeting。",
    "这个deadline太紧了。",
    "帮我review一下代码。",
    "这个feature先不做了。",
]

rows = []
def add(group, items, voices, lang):
    for index, (reference, terms, spoken) in enumerate(items):
        row = {"id": f"{len(rows):03d}_{group}", "lang": lang, "voice": voices[index % len(voices)],
               "reference": reference, "terms": terms, "control": not terms}
        if spoken:
            row["say"] = spoken
        rows.append(row)
add("en", english, EN, "en")
add("zh", chinese, ZH, "zh")
add("mixed", mixed, ZH, "mixed")
add("control_en", [(text, [], None) for text in controls_en], EN, "en")
add("control_zh", [(text, [], None) for text in controls_zh], ZH, "zh")
add("control_mixed", [(text, [], None) for text in controls_mixed], ZH, "mixed")
Path(__file__).with_name("sentences.jsonl").write_text("".join(json.dumps(row, ensure_ascii=False) + "\n" for row in rows), encoding="utf-8")
print(len(rows), "sentences,", sum(not r["control"] for r in rows), "with terms,", sum(r["control"] for r in rows), "controls")
