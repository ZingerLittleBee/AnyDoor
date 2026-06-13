// Bilingual strings. Both versions are rendered into the HTML and the active
// language is shown via [data-lang] on <html> + CSS rules in global.css.

export type Lang = 'zh' | 'en';
export type Bi<T = string> = { zh: T; en: T };

export const copy = {
  nav: { demo: { zh: '演示', en: 'Demo' }, why: { zh: '为什么', en: 'Why' }, features: { zh: '功能', en: 'Features' }, faq: { zh: 'FAQ', en: 'FAQ' }, download: { zh: '下载', en: 'Download' } },

  hero: {
    eyebrow: { zh: '一颗按键，一扇任意门', en: 'One key. Any door.' },
    h1a: { zh: '每个 App、每个系统开关，', en: 'Every app and system toggle,' },
    h1b: { zh: '一键直达。', en: 'one keystroke away.' },
    lede: {
      zh: 'AnyDoor 是为离不开键盘的开发者打造的 macOS 菜单栏控制中心。绑定任意按键来唤起 App、翻转系统开关、管理端口与 Hosts、运行内置动作——在 HID 层截获按键，快过你的肌肉记忆，双手永不离开键盘。',
      en: 'AnyDoor is a macOS menu bar control center built for developers who live on the keyboard. Bind any key to launch and toggle apps, flip system settings, manage ports and hosts, or run built-in actions — captured at the HID level, faster than your muscle memory, without ever leaving the keyboard.',
    },
    ctaPrimary: { zh: '下载 v', en: 'Download v' },
    ctaSecondary: { zh: '在 GitHub 上查看', en: 'View on GitHub' },
    meta1: { zh: '免费 & 开源', en: 'Free & open source' },
    meta2: { zh: 'macOS 14+', en: 'macOS 14+' },
    meta3: { zh: 'MIT 协议', en: 'MIT License' },
    pills: {
      zh: ['全局热键', '端口管理', '剪贴板历史', '命令面板', 'Hosts 管理', '显示器亮度', '窗口布局', '深色模式', '屏幕 OCR', '取色器', '识别二维码', 'Liquid Glass', 'Hyper Key'],
      en: ['Global hotkeys', 'Port manager', 'Clipboard history', 'Command palette', 'Hosts editor', 'Display brightness', 'Window layout', 'Dark mode', 'Screen OCR', 'Color picker', 'QR scan', 'Liquid Glass', 'Hyper Key'],
    },
  },

  why: {
    eyebrow: { zh: '为什么选 AnyDoor', en: 'Why AnyDoor' },
    h2a: { zh: '启动器负责搜索，', en: 'Launchers search.' },
    h2b: { zh: 'AnyDoor 控制系统。', en: 'AnyDoor controls your Mac.' },
    lede: {
      zh: '你大概已经在用 Raycast、Alfred 或 BetterTouchTool。AnyDoor 不替代它们的搜索，而是补上它们不碰、或要付费才有的那一层——系统级控制，免费、开源、纯本地。',
      en: 'You probably already use Raycast, Alfred, or BetterTouchTool. AnyDoor doesn’t replace their search — it adds the layer they leave out or charge for: system-level control, free, open source, and fully local.',
    },
    cards: [
      {
        icon: 'bolt',
        title: { zh: '免费 & 开源', en: 'Free & open source' },
        desc: { zh: 'MIT 协议，没有付费墙、没有 Pro 版本。Powerpack、BetterTouchTool、Raycast Pro 要收费的能力，这里全都免费，而且源码可审计。', en: 'MIT-licensed — no paywall, no Pro tier. What Powerpack, BetterTouchTool, and Raycast Pro charge for is free here, with source you can audit.' },
        vs: { zh: '对比：付费解锁', en: 'vs. paid unlocks' },
      },
      {
        icon: 'lock',
        title: { zh: '纯本地，无账号', en: 'Local, no account' },
        desc: { zh: '完全在设备上运行，没有遥测、统计，也不需要登录账号——不像云端启动器要联网注册。', en: 'Runs entirely on-device — no telemetry, no analytics, no sign-in to fumble through. Unlike cloud-account launchers.' },
        vs: { zh: '对比：云端登录', en: 'vs. cloud sign-in' },
      },
      {
        icon: 'server',
        title: { zh: '系统级控制', en: 'System-level control' },
        desc: { zh: '端口管理、Hosts 编辑、外接显示器亮度（DDC）、系统开关——启动器大多不碰的深度能力，一套热键直达。', en: 'Port management, hosts editing, external-display brightness (DDC), system toggles — the deep control launchers mostly don’t touch, one hotkey away.' },
        vs: { zh: '对比：仅搜索/命令', en: 'vs. search-only' },
      },
    ] as { icon: string; title: Bi; desc: Bi; vs: Bi }[],
  },

  features: {
    eyebrow: { zh: '不止于此', en: 'And there is more' },
    h2a: { zh: '一个菜单栏，', en: 'One menu bar,' },
    h2b: { zh: '一整套工具箱。', en: 'a whole toolbox.' },
    lede: {
      zh: '剪贴板历史、外接显示器亮度、窗口布局、Hosts 管理、命令面板——更多系统级能力，全都收进同一个面板、同一套热键。',
      en: 'Clipboard history, external-display brightness, window layout, hosts management, a command palette — more system-level power, folded into the same panel and the same hotkeys.',
    },
  },

  demo: {
    eyebrow: { zh: '全局热键', en: 'Global hotkeys' },
    h2a: { zh: '按一下打开，', en: 'Press to open.' },
    h2b: { zh: '再按一下隐藏。', en: 'Press again to hide.' },
    lede: {
      zh: '为每个常用 App 绑定一个组合键。AnyDoor 在 HID 层级别截获键盘事件，再快的肌肉记忆都赶得上。试试键盘上的 F1 – F6 →',
      en: "Bind a key combination to any app. AnyDoor intercepts keyboard events at the HID level, so it's faster than your muscle memory. Try F1 – F6 on the keyboard below →",
    },
    hintScreen: { zh: '↓ 按 F1 – F6 启动应用', en: '↓ Press F1 – F6 to launch' },
    hint: { zh: '试试按 F1 – F6', en: 'Try F1 – F6' },
    hintAfter: { zh: ' — 也可以试按 Esc 关闭。', en: ' — or hit Esc to dismiss.' },
    menuFile: { zh: '文件', en: 'File' },
    menuEdit: { zh: '编辑', en: 'Edit' },
    menuView: { zh: '显示', en: 'View' },
    modeFkeys: { zh: 'F 键模式', en: 'F-keys' },
    modeHyper: { zh: 'Hyper Key', en: 'Hyper Key' },
    hyperHint: {
      zh: '按住 ⇪ 再按字母键 — Hyper 把单键变成一整层快捷键',
      en: 'Hold ⇪ then a letter — Hyper turns one key into a whole shortcut layer',
    },
    hyperHintScreen: {
      zh: '↓ ⇪ + S F L M 触发 Hyper',
      en: '↓ ⇪ + S F L M for Hyper bindings',
    },
  },

  toggles: {
    eyebrow: { zh: '系统开关', en: 'System toggles' },
    h2a: { zh: '一键翻转每一个', en: 'Flip every setting' },
    h2b: { zh: '你常翻的设置。', en: 'you keep flipping.' },
    lede: {
      zh: '深色模式、静音、Keep Awake、隐藏 Dock、自动隐藏菜单栏……全部映射成简单的 Toggle。',
      en: 'Dark mode, mute, Keep Awake, hide Dock, auto-hide menu bar — all mapped to a single toggle, or a single key.',
    },
  },

  ports: {
    eyebrow: { zh: '端口管理器', en: 'Port Manager' },
    h2a: { zh: '哪个进程占了', en: "What's running" },
    h2b: { zh: ':3000？', en: 'on :3000?' },
    lede: {
      zh: '一个子菜单列出系统上每个正在监听的端口。按端口号或进程名搜索，平铺或按进程分组查看，扫描失败自动重试。',
      en: 'A submenu listing every listening port on the system. Search by port or process name. Flat list and process-grouped tree views. Live refresh with retry on scan failure.',
    },
    placeholder: { zh: '搜索端口或进程…', en: 'Search ports or processes...' },
    refresh: { zh: '刷新', en: 'Refresh' },
    tree: { zh: '树状视图', en: 'Tree View' },
    noMatch: { zh: '无匹配端口', en: 'No matching ports' },
    panelTitle: { zh: '端口管理', en: 'Port Manager' },
    appShortcuts: { zh: '应用快捷键', en: 'App Shortcuts' },
  },

  actions: {
    eyebrow: { zh: '内置动作', en: 'Built-in actions' },
    h2a: { zh: 'OCR、取色、截图，', en: 'OCR, color picker, capture —' },
    h2b: { zh: '都在一个键之内。', en: 'one key away.' },
    lede: {
      zh: '不只是 App 切换。绑定任意热键来运行 macOS 自带的内置动作——结果直接进入剪贴板。',
      en: 'AnyDoor is more than an app switcher. Bind any hotkey to run a built-in macOS action — results land directly on the clipboard.',
    },
    ocrName: { zh: '屏幕取词', en: 'Screen OCR' },
    ocrDesc: { zh: 'Vision 框架识别屏幕区域文字，自动复制到剪贴板。', en: 'Vision framework recognizes text in a screen region and copies it to the clipboard.' },
    ocrToast: { zh: '已复制到剪贴板', en: 'Copied to clipboard' },
    colorName: { zh: '屏幕取色', en: 'Pick Color' },
    colorDesc: { zh: '系统取色器把任意像素的 HEX 写入剪贴板。', en: 'System color sampler captures HEX into the clipboard.' },
    shotName: { zh: '区域截图', en: 'Region Screenshot' },
    shotDesc: { zh: '交互式区域截图，直接到剪贴板。', en: 'Interactive region capture, straight to the clipboard.' },
  },

  settings: {
    eyebrow: { zh: '设置面板', en: 'Settings' },
    h2a: { zh: '可拖拽排序的', en: 'Drag-to-reorder rows.' },
    h2b: { zh: '面板项与录入式快捷键。', en: 'Inline hotkey recorder.' },
    lede: {
      zh: '在「面板」标签页里：拖拽重排、按项隐藏、内联录入热键、类型徽标（开关 / 动作 / 子菜单）。「通用」标签页：开机启动、菜单栏图标样式、权限状态。',
      en: 'In the Panel tab: drag-to-reorder, per-item visibility, inline hotkey recorder, type badges (toggle / action / submenu). In the General tab: launch at login, menu bar icon style, accessibility & automation permissions.',
    },
    tabPanel: { zh: '面板', en: 'Panel' },
    tabGeneral: { zh: '通用', en: 'General' },
    record: { zh: '点击录入', en: 'Click to record' },
    hint: { zh: '系统条目无法删除，只能隐藏；应用快捷键可自由增删。', en: 'System items can be hidden but not removed; app shortcuts can be added or removed freely.' },
    badgeSubmenu: { zh: '子菜单', en: 'submenu' },
    badgeToggle: { zh: '开关', en: 'toggle' },
    badgeAction: { zh: '动作', en: 'action' },
    metaSystem: { zh: '系统', en: 'system' },
    metaSubmenu: { zh: '系统 · 子菜单', en: 'system · submenu' },
    metaAction: { zh: '系统 · 动作', en: 'system · action' },
    twoBindings: { zh: '2 个绑定', en: '2 bindings' },
    portsCount: { zh: '实时', en: 'Live' },
  },

  download: {
    eyebrow: { zh: '下载', en: 'Download' },
    h2a: { zh: '准备好了', en: 'Ready when' },
    h2b: { zh: '吗？', en: 'you are.' },
    lede: { zh: '免费、开源、本地运行，没有任何遥测。', en: 'Free, open source, runs entirely locally. No telemetry, no account.' },
    dmgTitle: { zh: '下载 .dmg', en: 'Download the .dmg' },
    dmgDesc: { zh: '签名 + 公证的安装包，集成 Sparkle 自动更新。', en: 'Signed + notarized installer with Sparkle auto-update built in.' },
    dmgBtn: { zh: '下载 AnyDoor v', en: 'Download AnyDoor v' },
    brewTitle: { zh: '或者用源码构建', en: 'Or build from source' },
    brewDesc: { zh: '从源码构建并安装到 /Applications。', en: 'Build the release binary and install to /Applications.' },
    copy: { zh: '复制', en: 'Copy' },
  },

  faq: {
    eyebrow: { zh: 'FAQ', en: 'FAQ' },
    h2: { zh: '一些常见的问题。', en: 'Some common questions.' },
    items: [
      {
        q: { zh: 'AnyDoor 是永久免费的吗？', en: 'Is AnyDoor really free?' },
        a: { zh: '是。AnyDoor 采用 MIT 协议，完全免费、开源，没有付费墙、订阅或 Pro 版本——Raycast Pro、Alfred Powerpack、BetterTouchTool 要收费的能力，这里全都免费。', en: 'Yes. AnyDoor is MIT-licensed — completely free and open source, with no paywall, subscription, or Pro tier. The kind of power Raycast Pro, Alfred Powerpack, and BetterTouchTool charge for is free here.' },
      },
      {
        q: { zh: 'AnyDoor 收集任何数据吗？', en: 'Does AnyDoor collect any data?' },
        a: { zh: '不。AnyDoor 完全在本地运行，没有任何遥测、统计或网络回传，也不需要账号登录。源码 100% 开源、可审计。', en: 'No. AnyDoor runs entirely on-device — no telemetry, no analytics, no network callbacks, and no account to sign in to. The source is 100% open and auditable.' },
      },
      {
        q: { zh: '和 Raycast、Alfred 有什么不同？', en: 'How is this different from Raycast or Alfred?' },
        a: { zh: '启动器擅长搜索与命令，AnyDoor 走得更深：它把 App 切换、系统开关、端口管理、Hosts 编辑、外接显示器亮度（DDC）、剪贴板历史收进同一套热键——这些大多是启动器不碰、或要付费才有的系统级控制。而且免费、开源、纯本地。', en: 'Launchers are great at search and commands; AnyDoor goes deeper. It folds app toggling, system switches, port management, hosts editing, external-display brightness (DDC), and clipboard history into one set of hotkeys — system-level control launchers mostly don’t touch, or charge for. And it’s free, open source, and fully local.' },
      },
      {
        q: { zh: '为什么需要辅助功能权限？', en: 'Why does it need accessibility permission?' },
        a: { zh: 'AnyDoor 通过 CGEvent tap 在 HID 层截获键盘事件，这是 macOS 实现全局热键的标准方式。所有事件处理都在本地完成，不会离开你的设备。', en: 'AnyDoor uses a CGEvent tap at the HID level to intercept keyboard events — the standard macOS path for global hotkeys. All event handling stays on your device.' },
      },
      {
        q: { zh: '会被 Gatekeeper 拦截吗？', en: 'Will Gatekeeper block it?' },
        a: { zh: '不会。.dmg 经过苹果开发者证书签名并公证（notarized），双击即可打开，不会弹出"无法验证开发者"的警告。', en: 'No. The .dmg is signed with an Apple Developer certificate and notarized, so it opens with a double-click — no “unidentified developer” warning.' },
      },
      {
        q: { zh: '支持 Intel Mac 吗？', en: 'Does it work on Intel Macs?' },
        a: { zh: '支持。安装包是 Universal Binary，原生运行于 Apple Silicon 与 Intel；外接显示器亮度会按架构自动选择 DDC 后端。', en: 'Yes. The build is a Universal Binary that runs natively on both Apple Silicon and Intel; the external-display brightness backend is chosen automatically per architecture.' },
      },
      {
        q: { zh: 'Liquid Glass 在我的 macOS 上能看到吗？', en: 'Will I see Liquid Glass on my macOS?' },
        a: { zh: 'Liquid Glass 效果在 macOS 26（Tahoe）上完整启用；macOS 14–25 会自动降级为标准的菜单材质，功能完全相同。', en: 'Liquid Glass effects light up on macOS 26 (Tahoe); macOS 14–25 fall back to the standard menu material — same features, same behaviour.' },
      },
      {
        q: { zh: '我可以自己从源码构建吗？', en: 'Can I build it from source myself?' },
        a: { zh: '可以。仓库里包含完整的 Make 流水线：make swift-release 构建二进制，make release <version> 做签名、公证、上传 GitHub Release 并更新 Sparkle appcast。', en: 'Yes. The repo ships a complete Make pipeline: `make swift-release` builds the binary, and `make release <version>` signs, notarizes, ships to GitHub Releases, and refreshes the Sparkle appcast.' },
      },
    ] as { q: Bi; a: Bi }[],
  },

  footer: {
    tagline: { zh: '一颗按键，一扇任意门。', en: 'One key. Any door.' },
    links: { zh: ['GitHub', 'Releases', 'CHANGELOG', 'MIT License'], en: ['GitHub', 'Releases', 'CHANGELOG', 'MIT License'] },
    built: { zh: 'Made with Swift 6.2 in 2026.', en: 'Made with Swift 6.2 in 2026.' },
  },
};
