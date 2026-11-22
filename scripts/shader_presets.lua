--[[
    Anime4K & 画质着色器预设管理器（支持一键切换 + 持久化保存 + uosc 菜单集成）
    - 快捷键：A 上一个预设 / D 下一个预设 / Shift+A 打开画质预设菜单
    - 控制栏按钮：button:shader_preset
    - 自动持久化到 ~~/saved-shader-preset.json，下次启动自动恢复
]]

local mp = require("mp")
local utils = require("mp.utils")
local msg = require("mp.msg")

local STATE_PATH = mp.command_native({"expand-path", "~~/saved-shader-preset.json"})

local PRESETS = {
    {
        id = "none",
        title = "原画（关闭着色器）",
        hint = "原始画面 · 最低功耗",
        badge = nil,
        shaders = {}
    },
    {
        id = "qcom",
        title = "轻锐化 · QCOM SGEDS",
        hint = "极轻负载 · 细节自然锐化",
        badge = "Q",
        shaders = {
            "~~/shaders/QCOM/QCOM_SGEDS_ms_RT.glsl"
        }
    },
    {
        id = "a4k_fast",
        title = "Anime4K 轻量清晰 (Mode A)",
        hint = "Restore M + Upscale CNN · 流畅追番",
        badge = "A4K",
        shaders = {
            "~~/shaders/Anime4K/Anime4K_Restore_CNN_M.glsl",
            "~~/shaders/Anime4K/Anime4K_Upscale_CNN_x2_M.glsl"
        }
    },
    {
        id = "a4k_hq",
        title = "Anime4K 高清重建 (Mode A+)",
        hint = "Restore L + Upscale GAN · 推荐 1080p 番剧",
        badge = "A4K+",
        shaders = {
            "~~/shaders/Anime4K/Anime4K_Restore_CNN_L.glsl",
            "~~/shaders/Anime4K/Anime4K_Upscale_GAN_x2_M.glsl"
        }
    },
    {
        id = "a4k_aio",
        title = "Anime4K 综合优化 (AIO Q)",
        hint = "一体化均衡增强",
        badge = "AIO",
        shaders = {
            "~~/shaders/Anime4K/Anime4K_AIO_optQ.glsl"
        }
    },
    {
        id = "a4k_restore",
        title = "Anime4K 降噪修复（老番 / 低码率）",
        hint = "Denoise + Restore GAN + Upscale CNN",
        badge = "FIX",
        shaders = {
            "~~/shaders/Anime4K/Anime4K_Denoise_Bilateral_Mode.glsl",
            "~~/shaders/Anime4K/Anime4K_Restore_GAN_UL_R2.glsl",
            "~~/shaders/Anime4K/Anime4K_Upscale_CNN_x2_M.glsl"
        }
    },
    {
        id = "artcnn",
        title = "Ani4Kv2 ArtCNN（锐利线条）",
        hint = "高画质 2D 动画线条超分",
        badge = "CNN",
        shaders = {
            "~~/shaders/Ani/Ani4Kv2_ArtCNN_C4F32_i2.glsl"
        }
    },
    {
        id = "fsrcnnx",
        title = "FSRCNNX 16x（自然放大）",
        hint = "线条温和自然 · 通用动画/实拍",
        badge = "FSR",
        shaders = {
            "~~/shaders/FSRCNNX/FSRCNNX_x2_16_0_4_1.glsl"
        }
    }
}

local DEBAND_SHADER = "~~/shaders/Deband/hdeband.glsl"
local MEMC_VF = 'vapoursynth="~~/vs/MEMC_MVT_LQ.vpy"'

local state = {
    preset = "a4k_hq",
    deband = false,
    memc = false
}

local function find_preset(id)
    for idx, p in ipairs(PRESETS) do
        if p.id == id then return p, idx end
    end
    return PRESETS[1], 1
end

local function load_state()
    local f = io.open(STATE_PATH, "rb")
    if not f then return end
    local raw = f:read("*a")
    f:close()
    if not raw or raw == "" then return end
    local parsed = utils.parse_json(raw)
    if type(parsed) == "table" then
        if type(parsed.preset) == "string" then state.preset = parsed.preset end
        if type(parsed.deband) == "boolean" then state.deband = parsed.deband end
        if type(parsed.memc) == "boolean" then state.memc = parsed.memc end
    end
end

local function save_state()
    local encoded = utils.format_json(state)
    if not encoded then return end
    local f = io.open(STATE_PATH, "wb")
    if not f then
        msg.warn("无法保存着色器状态到: " .. STATE_PATH)
        return
    end
    f:write(encoded)
    f:close()
end

local function update_uosc_button()
    local p = find_preset(state.preset)
    local is_active = (p.id ~= "none") or state.deband or state.memc
    local badge = p.badge
    if state.memc then
        badge = badge .. "·60"
    end
    local tooltip = "画质预设：" .. p.title .. "（A/D 切换 · 自动保存）"
    mp.commandv("script-message-to", "uosc", "set-button", "shader_preset", utils.format_json({
        icon = "auto_fix_high",
        active = is_active,
        badge = badge,
        tooltip = tooltip,
        command = "script-message-to shader_presets open-menu"
    }))
end

local function apply_state(show_osd)
    local p = find_preset(state.preset)
    local list = {}
    for _, s in ipairs(p.shaders) do
        table.insert(list, mp.command_native({"expand-path", s}))
    end
    if state.deband then
        table.insert(list, mp.command_native({"expand-path", DEBAND_SHADER}))
    end

    mp.set_property_native("glsl-shaders", list)

    if state.memc then
        mp.commandv("vf", "set", MEMC_VF)
    else
        -- Only clear if our MEMC filter is present
        local vf_list = mp.get_property_native("vf") or {}
        for _, v in ipairs(vf_list) do
            if v.name == "vapoursynth" then
                mp.commandv("vf", "clr", "")
                break
            end
        end
    end

    update_uosc_button()

    if show_osd then
        local extra = {}
        if state.deband then table.insert(extra, "去色带") end
        if state.memc then table.insert(extra, "60fps补帧") end
        local suffix = #extra > 0 and ("  + " .. table.concat(extra, " · ")) or ""
        mp.osd_message("画质预设：" .. p.title .. suffix .. "（已记住）", 2.2)
    end
end

local function open_menu()
    local items = {}
    for _, p in ipairs(PRESETS) do
        local selected = (p.id == state.preset)
        table.insert(items, {
            title = p.title,
            hint = p.hint,
            icon = selected and "radio_button_checked" or "radio_button_unchecked",
            active = selected,
            value = { "script-message-to", "shader_presets", "select", p.id }
        })
    end

    table.insert(items, { title = "附加增强（可与预设叠加）", selectable = false, muted = true, italic = true, separator = true })
    table.insert(items, {
        title = "去色带 (hdeband)",
        hint = state.deband and "已开启" or "已关闭",
        icon = state.deband and "check_box" or "check_box_outline_blank",
        active = state.deband,
        keep_open = true,
        value = { "script-message-to", "shader_presets", "toggle-deband" }
    })
    table.insert(items, {
        title = "60fps 补帧 (MVTools 快速)",
        hint = state.memc and "已开启" or "已关闭",
        icon = state.memc and "check_box" or "check_box_outline_blank",
        active = state.memc,
        keep_open = true,
        value = { "script-message-to", "shader_presets", "toggle-memc" }
    })

    local menu = {
        type = "shader_presets_menu",
        title = "Anime4K & 画质预设",
        footnote = "切换后自动保存，下次打开 MPV 自动恢复（快捷键 A / D 循环切换）",
        items = items
    }
    mp.commandv("script-message-to", "uosc", "open-menu", utils.format_json(menu))
end

local function select_preset(id)
    local p = find_preset(id)
    state.preset = p.id
    save_state()
    apply_state(true)
end

local function cycle_preset(delta)
    local _, idx = find_preset(state.preset)
    local next_idx = ((idx - 1 + delta) % #PRESETS) + 1
    select_preset(PRESETS[next_idx].id)
end

mp.register_script_message("open-menu", open_menu)
mp.register_script_message("select", select_preset)
mp.register_script_message("prev", function() cycle_preset(-1) end)
mp.register_script_message("next", function() cycle_preset(1) end)
mp.register_script_message("toggle-deband", function()
    state.deband = not state.deband
    save_state()
    apply_state(true)
    open_menu()
end)
mp.register_script_message("toggle-memc", function()
    state.memc = not state.memc
    save_state()
    apply_state(true)
    open_menu()
end)

-- Re-sync button when uosc reports ready
mp.register_script_message("uosc-version", function()
    update_uosc_button()
end)

-- Initialize & restore persisted shaders immediately on startup
load_state()
apply_state(false)
mp.add_timeout(0.6, update_uosc_button)
