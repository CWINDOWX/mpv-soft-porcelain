# Soft Porcelain MPV

一套基于 [`mpv-lazy`](https://github.com/hooke007/mpv_PlayKit) 定制的亮色系 MPV 番剧播放器配置（`portable_config`）。

风格偏向浅灰白极简质感，开箱即用，集成自动弹幕、弹幕样式调节、画质预设、OP/ED 跳过和 Bangumi 进度同步。

> [!NOTE]
> 本仓库仅包含 `portable_config` 配置文件与脚本，不含 MPV 程序本体。请先下载 `mpv-lazy` 后再替换其中的 `portable_config` 目录。

---

## 预览

![主界面](docs/screenshots/player-overview.png)

| 画质预设 | 弹幕样式面板 |
| :---: | :---: |
| ![画质预设](docs/screenshots/shader-menu.png) | ![弹幕样式面板](docs/screenshots/style-panel.png) |

---

## 核心功能

- **浅色极简界面**
  - 柔雾瓷白配色，圆角边框、常驻顶栏、浮动控制栏与进度条。
  - 顶部栏自动显示当前番剧名、集数和单集标题，点击可切换显示原文件名。
  - 右键菜单和底栏菜单就近弹出，适合追番场景。
- **自动弹幕与样式面板**
  - 打开本地番剧自动匹配并加载弹幕，支持手动搜索、添加外部弹幕源和调整延迟。
  - 提供可视化弹幕样式面板（`Ctrl+Shift+D`），可实时拖动调整字号、透明度、显示区域、速度、描边、阴影和密度，并支持一键风格预设、字体切换、弹幕屏蔽与简繁转换。
- **画质预设**
  - 内置原画、轻锐化、Anime4K、ArtCNN、FSRCNNX 等 8 档常用预设，支持叠加去色带和 60fps 补帧。
  - 切换后自动保存，下次打开自动恢复。
- **跳过 OP / ED**
  - 自动识别视频内嵌的片头、片尾和预告章节。
  - 支持右下角弹窗询问、自动跳过、关闭三种模式，自动跳过后可按 `Alt+Backspace` 退回。
- **Bangumi 进度同步**
  - 自动识别当前播放的番剧与集数，支持一键标记本集已看，并在菜单内实时显示请求结果。
  - 支持片尾提醒同步、自动同步或仅手动同步，剪贴板粘贴 Access Token 即可登录。

---

## 安装与使用

1. 下载并解压 Windows 版 [`mpv-lazy`](https://github.com/hooke007/mpv_PlayKit)。
2. 备份原有的 `portable_config` 目录，将本仓库克隆为 `mpv-lazy\portable_config`：
   ```bash
   git clone https://github.com/CWINDOWX/mpv-soft-porcelain.git portable_config
   ```
3. 将视频拖入 `mpv.exe` 即可使用。

### 简单配置

- **Bangumi 登录**：按 `Ctrl+B`（或点底栏书签图标）打开菜单 → 打开页面生成并复制 Access Token → 点击「从剪贴板登录」。登录信息仅保存在本地 `bangumi-auth.json`。
- **弹幕接口**：可在 `script-opts/uosc_danmaku.conf` 中修改 `api_server`，建议按需更换为自己的弹幕中继地址。

---

## 常用快捷键

| 功能 | 快捷键 |
| :--- | :--- |
| 右键主菜单 | 鼠标右键 / 中键 |
| 播放列表 | `Tab` |
| 弹幕开关 | `Z` |
| 弹幕样式面板 | `Ctrl+Shift+D` |
| 搜索弹幕 / 弹幕管理 | `Ctrl+D` / `Shift+D` |
| 画质预设菜单 | `Shift+A` |
| 切换上 / 下一个画质预设 | `A` / `D` |
| 跳过当前 OP / ED | `S` |
| OP / ED 跳过设置 | `Shift+S` |
| 撤销自动跳过 | `Alt+Backspace` |
| Bangumi 同步菜单 | `Ctrl+B` |
| 截图（含字幕 / 完整窗口） | `Ctrl+S` / `Ctrl+Shift+S` |
| 调节倍速 | `[` / `]` 或 `{` / `}` |
| 快捷键一览 | `Ctrl+I` |

---

## 致谢与协议

本仓库中的原创脚本与主题修改采用 **MIT License**，引用的第三方组件均保留原版权与协议（详情见 [LICENSE.md](LICENSE.md)）：

| 组件 | 来源 | 协议 |
| :--- | :--- | :--- |
| mpv-lazy / mpv_PlayKit | [hooke007/mpv_PlayKit](https://github.com/hooke007/mpv_PlayKit) | CC BY-NC-SA 4.0 / 混合协议 |
| uosc | [tomasklaen/uosc](https://github.com/tomasklaen/uosc) | LGPL-2.1 |
| uosc_danmaku | [Tony15246/uosc_danmaku](https://github.com/Tony15246/uosc_danmaku) | MIT |
| thumbfast | [po5/thumbfast](https://github.com/po5/thumbfast) | MPL-2.0 |
| contextmenu_plus | [tsl0922/mpv-menu-plugin](https://github.com/tsl0922/mpv-menu-plugin) | GPL-2.0-only |
| Anime4K / ArtCNN / FSRCNNX 等着色器 | 见各 `.glsl` 文件头 | MIT / BSD / LGPL / CC BY-NC 4.0 |
| 霞鹜文楷 Mono Lite / Material Icons | [LxgwWenKai](https://github.com/lxgw/LxgwWenKai) / Google | SIL OFL 1.1 / Apache-2.0 |

> [!IMPORTANT]
> 因包含非商业（`CC BY-NC`）及 `GPL-2.0-only` / `LGPL` 组件，本整合配置仅供个人非商业使用。
