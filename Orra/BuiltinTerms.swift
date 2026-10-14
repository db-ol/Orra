/// Names people say often in Chinese and English tech speech that a speech model trained
/// before them may not know or may spell its own way: AI models and companies, developer
/// tools, Apple products, apps and Chinese platforms. The speech model gets them as context
/// after the user's own words when the user has some, see `forModel(after:from:limit:)`,
/// so a user's spelling always comes first.
///
/// Curated by hand for 2026 and ordered by how often a dictation is likely to name them,
/// since only the first ones are given when the user's vocabulary is long. Each entry is
/// written the way its owner writes it. Plain words that a model knows anyway, such as
/// "prompt" or "token", are left out, and so are names that are also everyday words in
/// lower case (Go, Bun, Arc, Teams) apart from a few that are almost always the product.
/// Tools/terms-eval measures the list, see its README.
nonisolated enum BuiltinTerms {
    /// The names a dictation is most likely to hold, given first.
    static let common: [String] = [
        // AI assistants, models and companies.
        "ChatGPT", "GPT-5", "OpenAI", "Claude", "Claude Code", "Anthropic", "Gemini",
        "DeepSeek", "Qwen", "Qwen3.5", "Llama", "Copilot", "Cursor", "Kimi", "Grok",
        "Perplexity", "Midjourney", "Ollama", "Hugging Face", "ModelScope", "LangChain",
        "MCP", "LLM", "RAG", "AGI", "AIGC", "Codex", "Sora", "Mistral", "NotebookLM",
        // Chinese AI products and companies.
        "豆包", "通义千问", "千问", "文心一言", "腾讯元宝", "元宝", "智谱", "月之暗面", "即梦", "可灵", "火山引擎", "扣子",
        // Chinese apps and platforms.
        "微信", "企业微信", "飞书", "钉钉", "小红书", "抖音", "快手", "哔哩哔哩", "B站", "知乎", "微博", "淘宝", "京东",
        "拼多多", "美团", "支付宝", "腾讯会议", "剪映", "鸿蒙", "华为", "小米", "字节跳动", "阿里巴巴", "阿里云", "腾讯",
        "百度",
        // Developer tools, languages and services.
        "GitHub", "Xcode", "SwiftUI", "Swift", "TypeScript", "JavaScript", "Python",
        "PyTorch", "CUDA", "Kubernetes", "Docker", "React", "Next.js", "Node.js",
        "PostgreSQL", "Redis", "AWS", "Vercel", "Supabase", "Cloudflare", "VS Code",
        "Linux",
        // Apple, devices and chips.
        "iPhone", "iPad", "MacBook", "MacBook Pro", "Mac mini", "AirPods", "Apple Watch",
        "Vision Pro", "macOS", "iOS", "iCloud", "Apple Intelligence", "Nvidia", "Android",
        // Apps and services.
        "Notion", "Figma", "Slack", "Discord", "Zoom", "Gmail", "Obsidian", "Linear",
        "Jira", "YouTube", "TikTok", "Telegram", "WhatsApp", "LinkedIn", "Excel",
        "PowerPoint",
    ]

    /// More names. The app gives only `common` for now: on the synthetic clips of
    /// Tools/terms-eval, the 120 common terms wrote 75.9% of spoken terms exactly, the first
    /// 200 of all 73.5% and all 304 72.3%, and each longer list decodes slower.
    static let more: [String] = [
        // AI assistants, models and companies.
        "Qwen3", "GitHub Copilot", "GPT-4o", "o3", "DeepSeek-R1", "DeepSeek-V3",
        "Gemini 2.5", "Claude Opus", "Claude Sonnet", "Nano Banana", "Veo",
        "Stable Diffusion", "Whisper", "Qwen3-ASR", "MiniMax", "GLM", "ChatGLM",
        "Llama.cpp", "vLLM", "MLX", "LM Studio", "LlamaIndex", "Windsurf", "Trae", "Manus",
        "Coze", "Dify", "n8n", "DeepMind", "xAI", "Gemma",
        // Chinese AI products and companies.
        "通义", "文心", "混元", "智谱清言", "深度求索", "讯飞星火", "科大讯飞", "海螺", "魔搭", "盘古", "昇腾", "通义灵码",
        "百炼", "阶跃星辰", "商汤", "百川",
        // Chinese apps and platforms.
        "天猫", "饿了么", "滴滴", "高德地图", "百度网盘", "夸克", "QQ", "网易云音乐", "闲鱼", "携程", "得物",
        "HarmonyOS", "大疆", "腾讯云", "网易", "比亚迪", "蔚来", "理想汽车", "小鹏", "问界", "华为云", "麒麟",
        "澎湃OS", "WPS",
        // Developer tools, languages and services.
        "GitLab", "Git", "TensorFlow", "JAX", "Rust", "Kotlin", "React Native", "Vue",
        "Vite", "Tailwind", "Flutter", "GraphQL", "MySQL", "MongoDB", "SQLite", "Kafka",
        "Elasticsearch", "Terraform", "Azure", "Google Cloud", "Netlify", "Firebase",
        "Homebrew", "npm", "pnpm", "JetBrains", "IntelliJ", "PyCharm", "Neovim", "Vim",
        "Jupyter", "Colab", "Kaggle", "Ubuntu", "WebAssembly", "WebGPU", "Electron",
        "Tauri", "Django", "FastAPI", "Spring Boot", "Postman", "Sentry", "Grafana",
        "Prometheus", "Nginx", "Stack Overflow", "LeetCode", "TestFlight", "Swift Package",
        "CocoaPods", "Core ML",
        // Apple, devices and chips.
        "iPhone 17", "iPhone Air", "iPad Pro", "MacBook Air", "Mac Studio", "iMac",
        "AirPods Pro", "iPadOS", "watchOS", "visionOS", "Siri", "FaceTime", "App Store",
        "Apple Silicon", "M5", "M4 Pro", "AMD", "Intel", "Qualcomm", "Snapdragon", "TSMC",
        "RTX", "H100", "Blackwell", "Windows", "Chrome", "Safari", "Firefox", "Raycast",
        // Apps and services.
        "Microsoft Teams", "Outlook", "Google Docs", "Google Drive", "Confluence", "Trello",
        "Asana", "Miro", "Canva", "Airtable", "Zapier", "Dropbox", "Spotify", "Instagram",
        "Reddit", "Threads", "Substack", "Stripe", "Shopify", "PayPal", "Netflix", "Uber",
        "Airbnb", "Tesla", "SpaceX", "Starlink", "Waymo", "Duolingo", "Keynote", "Loom",
        "Calendly", "1Password",
    ]

    /// Every built-in term, `common` first.
    static let all = common + more

    /// What the speech model gets with a dictation: the user's words as they are, then
    /// built-in terms the user's words do not hold, ignoring case, until there are
    /// `limit` in all. So a user's spelling wins, and a long vocabulary of the user's
    /// leaves no room for the built-in ones.
    ///
    /// Without words of the user's the model gets no context at all, as before. Measured
    /// on 2026-10-13 (Tools/terms-eval), any context, even 10 terms, makes the model
    /// write more Chinese numbers in words and raised cer_zh on the speech corpus from
    /// 3.98% to 5.0 to 5.4%. With a vocabulary the model has a context anyway, and the
    /// built-in terms added little on top of it.
    static func forModel(after userTerms: [String], from builtin: [String] = all, limit: Int = Vocabulary.modelLimit) -> [String] {
        guard !userTerms.isEmpty, userTerms.count < limit else { return userTerms }
        var seen = Set(userTerms.map { $0.lowercased() })
        var result = userTerms
        for term in builtin where result.count < limit && seen.insert(term.lowercased()).inserted {
            result.append(term)
        }
        return result
    }
}
