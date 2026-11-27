# Licensing Notice

This repository is a personal MPV `portable_config` customization suite combining original scripts/configurations with third-party open-source components.

## 1. Original Work (MIT License)

All original scripts, theme customizations, and documentation created specifically for this repository — including `scripts/bangumi_sync/`, `scripts/shader_presets.lua`, `scripts/chapter_skip.lua`, `scripts/speed_menu.lua`, `scripts/font_picker.lua`, `scripts/uosc_danmaku/modules/style_panel.lua`, and custom UI/theme modifications — are licensed under the **MIT License**:

```text
MIT License

Copyright (c) 2026 CWINDOWX

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## 2. Third-Party Components

All third-party scripts, shaders, binaries, and icon fonts bundled in this configuration remain under their respective original licenses and copyrights:

- **mpv_PlayKit / mpv-lazy** (`mpv.conf`, `profiles.conf`, `script-opts.conf`, `scripts/save_global_props.lua`, `vs/`): CC BY-NC-SA 4.0 / respective upstream licenses — https://github.com/hooke007/mpv_PlayKit
- **uosc** (`scripts/uosc/`): LGPL-2.1 — https://github.com/tomasklaen/uosc
- **uosc_danmaku** (`scripts/uosc_danmaku/`): MIT — https://github.com/Tony15246/uosc_danmaku (see `scripts/uosc_danmaku/LICENSE`)
- **thumbfast** (`scripts/thumbfast.lua`): MPL-2.0 — https://github.com/po5/thumbfast
- **GLSL Shaders** (`shaders/`): Individual licenses preserved in each `.glsl` file header, including MIT (Anime4K), Snapdragon GSR License (QCOM SGEDS), LGPL-2.1 (hdeband), LGPL-3.0 (FSRCNNX), and CC BY-NC 4.0 (Ani4Kv2 ArtCNN weights).
- **Icon Fonts** (`fonts/`):
  - `MaterialIconsRound-Regular.otf`: Apache License 2.0 — https://github.com/google/material-design-icons
  - `uosc_textures.ttf`: bundled with `uosc` (LGPL-2.1)

Because certain bundled components include non-commercial (`CC BY-NC`) and copyleft (`LGPL`) terms, **this repository as a combined distribution is intended for non-commercial personal use only**, and redistributions must preserve all original license headers and notices.
