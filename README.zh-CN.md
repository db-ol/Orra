<h1 align="center">
  <a href="https://db-ol.github.io/Orra/zh/"><img src="site/icon.png" alt="Orra" width="64" valign="middle"></a> Orra
</h1>

<p align="center">
  <a href="https://github.com/db-ol/Orra/releases/latest/download/Orra.dmg"><img src="https://img.shields.io/badge/%E4%B8%8B%E8%BD%BD-Orra.dmg-0A84FF?logo=apple&logoColor=white" alt="下载 Orra.dmg"></a>
  <a href="https://db-ol.github.io/Orra/zh/"><img src="https://img.shields.io/badge/%E5%AE%98%E7%BD%91-db--ol.github.io%2FOrra-555555?logo=safari&logoColor=white" alt="Orra 官网"></a>
  <a href="https://github.com/db-ol/Orra/releases"><img src="https://img.shields.io/github/v/release/db-ol/Orra?label=%E7%89%88%E6%9C%AC&color=0A84FF" alt="最新版本"></a>
</p>

<p align="center"><sub><a href="README.md">English</a> · 简体中文 · <a href="README.ja.md">日本語</a> · <a href="README.es.md">Español</a></sub></p>

<p align="center">
  <strong>开源的 Mac 语音输入 App。</strong><br>
  按一下键开始说话，说完再按一下，文字就会出现在你正在输入的 App 里。<br>
  语音在你自己的 Mac 上转成文字，从不经过服务器。
</p>

<h3 align="center"><a href="https://github.com/db-ol/Orra/releases/latest/download/Orra.dmg"><ins>下载 Orra</ins></a></h3>

<p align="center"><sub>适用于搭载 Apple 芯片、macOS 15.6 或更高版本的 Mac。Orra 目前是早期预览版，难免有不完善的地方，设计也还会调整。</sub></p>

## 功能

<table>
<tr>
<td width="50%" valign="middle">

### 在任何 App 里听写

说中文（普通话和粤语）、英文，或者一句话里中英混说。也可以在设置的“听写语言”里改选日语或西班牙语加英文（测试版）。Qwen3-ASR 1.7B 模型在你的 Mac 上把它写成文字，Orra 再粘贴到光标所在的位置。“呃”“um”“uh”这类语气词会去掉，说出来的中文数字，比如日期、价格和百分比，会写成阿拉伯数字。

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

可选功能。按一下第二个键开始说话，再按一下结束。把它的用法设为“按住”时，则按住它说话。Orra 会用同一个模型在你的 Mac 上，把你说的话在英文和你的听写语言（中文、日语或西班牙语）之间翻译后粘贴。小小的标记表示这次听写会被翻译：中文是“译”，日语是“訳”，西班牙语是“⇄”。

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

打开 Orra 后，欢迎窗口会带你下载模型、允许使用麦克风和辅助功能，并选择说话键和它的用法。[使用指南](docs/user-guide.zh-CN.md)介绍了每个功能和它的设置。

## 隐私

Orra 在你的 Mac 上把语音转成文字，从不把录音或文字发送到任何地方。它没有账号、没有统计，也没有自己的服务器。只有下载你要求的模型，以及在你允许后检查更新时，Orra 才会联网。“从我的修改中学习”“记住我的音色”这类会保存内容的功能，默认都是关闭的。

Orra 保存什么、什么时候联网、怎样删除模型，详见 [docs/privacy.zh-CN.md](docs/privacy.zh-CN.md)。

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
