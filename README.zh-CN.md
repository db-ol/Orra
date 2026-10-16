<h1 align="center">
  <a href="https://db-ol.github.io/Orra/zh/"><img src="site/icon.png" alt="Orra" width="64" valign="middle"></a> Orra
</h1>

<p align="center">
  <a href="https://github.com/db-ol/Orra/releases/latest/download/Orra.dmg"><img src="https://img.shields.io/badge/%E4%B8%8B%E8%BD%BD-Orra.dmg-0A84FF?logo=apple&logoColor=white" alt="下载 Orra.dmg"></a>
  <a href="https://db-ol.github.io/Orra/zh/"><img src="https://img.shields.io/badge/%E5%AE%98%E7%BD%91-db--ol.github.io%2FOrra-555555?logo=safari&logoColor=white" alt="Orra 官网"></a>
  <a href="https://github.com/db-ol/Orra/releases"><img src="https://img.shields.io/github/v/release/db-ol/Orra?label=%E7%89%88%E6%9C%AC&color=0A84FF" alt="最新版本"></a>
  <a href="https://github.com/db-ol/Orra/stargazers"><img src="https://img.shields.io/github/stars/db-ol/Orra?label=Stars&color=0A84FF" alt="GitHub Stars"></a>
</p>

<p align="center"><sub><a href="README.md">English</a> · 简体中文</sub></p>

<p align="center">
  <strong>开源的 Mac 语音输入 App。</strong><br>
  按住一个键说话，松开后，文字就会出现在你正在输入的 App 里。<br>
  语音在你自己的 Mac 上转成文字，从不经过服务器。
</p>

<h3 align="center"><a href="https://github.com/db-ol/Orra/releases/latest/download/Orra.dmg"><ins>下载 Orra</ins></a></h3>

<p align="center"><sub>适用于搭载 Apple 芯片、macOS 15.6 或更高版本的 Mac。Orra 目前是早期预览版，难免有不完善的地方，设计也还会调整。</sub></p>

## 功能

<table>
<tr>
<td width="50%" valign="middle">

### 在任何 App 里听写

说中文、英文，或者一句话里中英混说。Qwen3-ASR 1.7B 模型在你的 Mac 上把它写成文字，Orra 再粘贴到光标所在的位置。“呃”“um”“uh”这类语气词会去掉，说出来的中文数字，比如日期、价格和百分比，会写成阿拉伯数字。

</td>
<td width="50%"><img src="docs/images/readme/zh/dictation.gif" alt="按住说话键，有人说“呃，周三的 meeting notes 我整理好了，下午发到群里。”Orra 胶囊里的音量条随声音跳动，随后这句话出现在笔记里，“呃”已经去掉。" width="100%"></td>
</tr>
<tr>
<td width="50%" valign="middle">

### 你的词，你的写法

个人词库最多可以放 5000 个名字和术语，Orra 会按你的写法输出。打开学习功能后，你在听写后改正的词，Orra 会记住，下次就写对。

</td>
<td width="50%"><img src="docs/images/readme/zh/vocabulary.gif" alt="笔记里写着“这次用奥拉测了新版本。”有人把“奥拉”改成 Orra，Orra 弹出提示：已把“Orra”加入个人词库，原来听成了“奥拉”，可以撤销。下一次听写就写成了 Orra。" width="100%"></td>
</tr>
<tr>
<td width="50%" valign="middle">

### 用本地模型整理文字

可选功能。你 Mac 上的文字模型会去掉规则漏掉的语气词，并按你说出口的更正改好内容，比如“三点，哦不对，四点”会写成“四点”。用“粘贴原文”随时可以找回你说的原话。

</td>
<td width="50%"><img src="docs/images/readme/zh/cleanup.gif" alt="打开“整理文字”后，有人说“明天下午三点，哦不对，四点，跟客户过一下报价。”邮件里出现“明天下午四点跟客户过一下报价。”" width="100%"></td>
</tr>
<tr>
<td width="50%" valign="middle">

### 翻译键

可选功能。按住第二个键说话，Orra 会用同一个模型在你的 Mac 上把中文翻译成英文、英文翻译成中文后粘贴。小小的“译”字标记表示这次听写会被翻译。

</td>
<td width="50%"><img src="docs/images/readme/zh/translation.gif" alt="在聊天窗口里，Sam 问“When can I see the designs?”。有人按住翻译键说“我这边周五之前能把设计稿发给你。”胶囊里显示“译”字标记，输入框里出现“I can send you the designs before Friday.”" width="100%"></td>
</tr>
<tr>
<td width="50%" valign="middle">

### 会议同传

跨语言开会时使用。对方说的话，你看到自己语言的字幕。你说自己的语言，对方听到的是他们的语言，还可以是你的音色。**实时字幕**把 Mac 播放的声音（比如通话）翻译成字幕，显示在一个浮动窗口里。**为对方朗读译文**用你 Mac 上的语音合成模型，把你用翻译键说的话读出来，送进 Orra Microphone 虚拟设备，通话另一方就能听到你说的话的译文。

0.4.0 新增。

</td>
<td width="50%"><img src="docs/images/readme/zh/meeting.gif" alt="视频会议里，Alex 说英文，“实时字幕”窗口逐句显示原文和中文译文。然后用户按住翻译键说“可以，我周三之前把测试做完。”，通话里从 Orra Microphone 听到“Sure, I’ll finish testing by Wednesday.”" width="100%"></td>
</tr>
<tr>
<td width="50%" valign="middle">

### 在 App 里更新

只有你允许后，Orra 才会检查新版本，也只在你选择后才安装。每个更新都经过签名。

</td>
<td width="50%"><img src="docs/images/readme/zh/updates.gif" alt="菜单栏里 Orra 的菜单，选中“检查更新…”。一个窗口提示有新版本，下载后显示“安装并重新启动”。" width="100%"></td>
</tr>
</table>

## 安装

- **[下载最新版本的 Orra.dmg](https://github.com/db-ol/Orra/releases/latest/download/Orra.dmg)**，打开后把 Orra 拖进“应用程序”。旧版本和更新说明在[版本发布页面](https://github.com/db-ol/Orra/releases)。
- **Orra Microphone**（可选，用于“为对方朗读译文”）：下载已签名并经过公证的 [OrraMicrophone.pkg](https://github.com/db-ol/Orra/releases/download/v0.4.0/OrraMicrophone.pkg)，打开即可安装。[Drivers/OrraMicrophone](Drivers/OrraMicrophone/README.md)（英文）说明了如何移除它，或者自己构建。
- 需要搭载 Apple 芯片、macOS 15.6 或更高版本的 Mac，以及大约 3 GB 的可用空间。可选的本地模型（用来整理和翻译）另需 2.8 GB，“为对方朗读译文”可选的语音合成模型另需约 2 GB。
- 使用 Developer ID 签名并经过苹果公证，打开时不会出现安全警告。
- 不在 Mac App Store 上架，因为 App Store 的沙盒不允许 App 在其他 App 里监听按键或粘贴文字。

打开 Orra 后，欢迎窗口会带你下载模型、允许使用麦克风和辅助功能，并选择说话键。[使用指南](docs/user-guide.zh-CN.md)介绍了每个功能和它的设置。

## 隐私

Orra 在你的 Mac 上把语音转成文字，从不把录音或文字发送到任何地方。它没有账号、没有统计，也没有自己的服务器。粘贴的文字只留在这台 Mac 的剪贴板上，所以“通用剪贴板”不会把它同步到你的其他设备。

**从你的修改中学习**默认关闭。打开后，每次粘贴后的 3 分钟内，只要你还在那个输入框里，Orra 会通过 macOS 辅助功能每秒读取一次它刚粘贴进去的那个输入框的文字。它最多读取 20,000 个字符，文字只在这几分钟里保存在内存中，从不写到任何地方。它从不读取密码框，也不读取开启了“安全输入”的 App。它只保存词对，比如“奥拉”和“Orra”，以及每对出现的次数和时间，存放在 ~/Library/Application Support/io.github.db-ol.Orra/corrections.json，只出现过一次的词对一周后会被删除。连续三位以上的数字，比如验证码、金额和年份，从不保存。Orra 只在出现已保存词对里听错的写法时修改听写出来的文字。在设置里点“清除学到的修改”会删除所有词对。

**会议同传**的字幕和声音样本里说的话都只保存在内存中。声音样本也只保存在内存中，除非你打开“记住我的音色”，这个开关默认关闭。Orra 从不把文字或音频写进日志。

**Orra 只在下载你要求的模型和检查更新时联网。**

- **语音模型**，只在你选择“下载语音模型”，或在欢迎窗口里点按“下载模型”之后：六个文件，共 2.47 GB，从 Hugging Face（huggingface.co）下载。如果连不上 Hugging Face，比如在中国大陆，Orra 会依次尝试 ModelScope（modelscope.cn）和 hf-mirror.com，它们提供相同的文件。Orra 会用写在源代码里的数值核对每个文件的大小和 SHA-256 校验值，所以镜像站无法篡改模型。文件存放在 ~/Library/Application Support/io.github.db-ol.Orra/Models，不会被时间机器备份。
- **整理模型**，只在你点按欢迎窗口里的“下载模型”或“下载整理模型”之后（欢迎窗口在内存 16 GB 及以上的 Mac 上为新用户提供，整理文字打开时也会提供），或在设置里打开“整理文字”或“翻译”并同意下载之后：mlx-community/Qwen3.5-4B-4bit 的四个文件，共 3.05 GB，从同样的服务器下载，用同样的方式核对，存放在 Models 里它自己的文件夹中。
- **语音合成模型**，只在你为“为对方朗读译文”开始下载之后：Qwen3-TTS，约 2 GB，从 Hugging Face 或 hf-mirror.com 下载，用同样的方式核对。
- **检查更新**，只在你允许之后。Orra 第二次启动时会问你是否自动检查，也可以在“设置 → 关于”里更改。检查时，Orra 大约每天读取一次 https://github.com/db-ol/Orra/releases/latest/download/appcast.xml。每次更新都要你同意后才会安装，而且只安装用本项目更新密钥签名的更新和更新清单。

模型都在你的 Mac 上运行，本身从不联网。在你允许检查更新之前，启动 Orra 从不联网。和所有下载一样，这些服务能看到你的 IP 地址。检查更新时还会看到 Orra 的版本号，以及和所有网页请求一样带上的偏好语言。Orra 不发送账号、令牌或 Cookie，也不发送任何其他关于你的 Mac 的信息。服务器和核对方式的详情见 [docs/model-download.md](docs/model-download.md)（英文）。

**报告问题**会在你的 Mac 上生成一个文本文件，包括 Orra 的版本、设置和权限状态，Mac 的型号、芯片、内存、macOS 版本和语言，麦克风名称，Orra 最近一小时的日志，以及最近 7 天的崩溃报告。它不包含任何听写的文字、录音、剪贴板、个人词库或学到的词。你的个人文件夹路径、账户名、全名和电脑名都会被去掉。Orra 自己不发送任何东西，它只是在浏览器里打开 GitHub 页面，只有你自己附上，这个文件才会到 GitHub。

要删除模型，请先退出 Orra，再删除上面的 Models 文件夹。如果只想删除整理模型，请先关闭整理和翻译，再删除其中的 Qwen3.5-4B-4bit-0e7ffd5c 文件夹。如果 ~/Library/Caches/qwen3-speech 里有其他 App 留下的副本，也请一并删除，否则 Orra 会从那里重新安装模型。

## 社区与支持

- **报告问题。** 在 Orra 的菜单里选择“报告问题…”，或者直接在 [GitHub 上提交问题](https://github.com/db-ol/Orra/issues/new/choose)。请不要附上你听写的私人内容。
- **疑问和建议。** 欢迎在 [Discussions](https://github.com/db-ol/Orra/discussions) 提问。
- **微信。** 扫码加入 Orra 微信群。<br>
  <img src="docs/images/wechat-group.png" alt="Orra 微信群二维码" width="160">
- **支持 Orra。** 如果 Orra 对你有用，欢迎在 [GitHub 上给它点个 Star](https://github.com/db-ol/Orra)。

## 开发者

Orra 用 Swift 和 SwiftUI 编写。[docs/development.md](docs/development.md) 介绍了如何构建和测试、代码结构以及如何发布版本（英文）。修改代码前请先阅读 [AGENTS.md](AGENTS.md)。

## 许可证

MIT，见 [LICENSE](LICENSE)。
