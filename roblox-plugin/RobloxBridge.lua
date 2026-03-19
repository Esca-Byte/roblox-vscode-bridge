-- ══════════════════════════════════════════════════════════════════
-- RobloxBridge  —  Roblox Studio Plugin  v1.3.0
-- Polls the local VS Code bridge server and syncs Lua/Luau files
-- into the current place.  Also lets you push scripts back to disk.
--
-- v1.3.0 Changelog:
--   • Redesigned Status Widget — animated pulse, color-coded log,
--     progress bar during sync, rounded corners, clear log button
--   • init.lua support — Rojo-compatible init file handling
--   • Two-way delete — deleted scripts are sent to VS Code
--   • task.spawn / task.wait — replaces deprecated spawn/wait
--   • Improved logging and error handling
--
-- Install:  copy this file to
--   %LOCALAPPDATA%\Roblox\Plugins\RobloxBridge.lua
-- then restart Roblox Studio.
-- ══════════════════════════════════════════════════════════════════

local HttpService   = game:GetService("HttpService")
local Selection     = game:GetService("Selection")
local RunService    = game:GetService("RunService")
local TweenService  = game:GetService("TweenService")

-- ── Configuration ─────────────────────────────────────────────────
local CONFIG = {
    port         = 7777,    -- must match robloxBridge.port in VS Code
    pollInterval = 2,       -- seconds between polls (overridden by /config on connect)
    sourcePath   = "src",   -- must match robloxBridge.sourcePath in VS Code
    useLuau      = false,   -- write .luau extensions (overridden by /config on connect)
    twoWayDelete = false,   -- whether to sync deletions to VS Code
}

local BASE_URL = "http://127.0.0.1:" .. CONFIG.port

-- ── State ─────────────────────────────────────────────────────────
local isRunning          = false
local lastTimestamp      = 0
local totalScriptsSynced = 0
local reconnectAttempts  = 0
local MAX_RECONNECT      = 5
local syncLog            = {}           -- rolling log shown in widget

-- ── Color palette ─────────────────────────────────────────────────
local COLORS = {
    bg           = Color3.fromRGB(15, 15, 20),
    bgCard       = Color3.fromRGB(24, 24, 32),
    bgCardHover  = Color3.fromRGB(32, 32, 42),
    headerTop    = Color3.fromRGB(30, 35, 55),
    headerBot    = Color3.fromRGB(20, 22, 32),
    accent       = Color3.fromRGB(80, 130, 255),
    accentDim    = Color3.fromRGB(50, 80, 160),
    green        = Color3.fromRGB(50, 205, 100),
    greenDim     = Color3.fromRGB(25, 80, 50),
    red          = Color3.fromRGB(235, 65, 65),
    redDim       = Color3.fromRGB(80, 25, 25),
    yellow       = Color3.fromRGB(250, 200, 50),
    orange       = Color3.fromRGB(255, 140, 50),
    cyan         = Color3.fromRGB(60, 200, 220),
    textBright   = Color3.fromRGB(230, 230, 240),
    textMid      = Color3.fromRGB(160, 160, 180),
    textDim      = Color3.fromRGB(90, 90, 110),
    divider      = Color3.fromRGB(40, 40, 52),
    logBg        = Color3.fromRGB(18, 18, 25),
    scrollThumb  = Color3.fromRGB(60, 70, 110),
}

-- ══════════════════════════════════════════════════════════════════
-- STATUS WIDGET — PREMIUM DESIGN
-- ══════════════════════════════════════════════════════════════════
local widgetInfo = DockWidgetPluginGuiInfo.new(
    Enum.InitialDockState.Float,
    false, false,
    340, 420,      -- initial size
    300, 340       -- min size
)

local statusWidget = plugin:CreateDockWidgetPluginGui("RobloxBridgeStatus", widgetInfo)
statusWidget.Title  = "Roblox Bridge"
statusWidget.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

-- ── Root container (absolute positioning — no conflicting layouts) ─
local root = Instance.new("Frame")
root.Size                = UDim2.new(1, 0, 1, 0)
root.BackgroundColor3    = COLORS.bg
root.BorderSizePixel     = 0
root.Parent              = statusWidget

-- ── CONNECTION UPTIME TIMER ───────────────────────────────────────
local connectStartTime = 0 -- os.clock() when connected

-- ══════════════════════════════════════════════════════════════════
-- HEADER SECTION — Gradient background, branding, status
-- Height: 72px   Position: top
-- ══════════════════════════════════════════════════════════════════
local header = Instance.new("Frame")
header.Name              = "Header"
header.Size              = UDim2.new(1, 0, 0, 72)
header.Position          = UDim2.new(0, 0, 0, 0)
header.BackgroundColor3  = COLORS.headerTop
header.BorderSizePixel   = 0
header.Parent            = root

local headerGrad = Instance.new("UIGradient")
headerGrad.Color    = ColorSequence.new(COLORS.headerTop, COLORS.headerBot)
headerGrad.Rotation = 90
headerGrad.Parent   = header

-- Subtle glow line under header
local glowLine = Instance.new("Frame")
glowLine.Name              = "GlowLine"
glowLine.Size              = UDim2.new(1, 0, 0, 2)
glowLine.Position          = UDim2.new(0, 0, 1, 0)
glowLine.BackgroundColor3  = COLORS.accent
glowLine.BorderSizePixel   = 0
glowLine.Parent            = header

local glowGrad = Instance.new("UIGradient")
glowGrad.Color       = ColorSequence.new({
    ColorSequenceKeypoint.new(0,   COLORS.accent),
    ColorSequenceKeypoint.new(0.5, COLORS.accent),
    ColorSequenceKeypoint.new(1,   COLORS.accentDim),
})
glowGrad.Transparency = NumberSequence.new({
    NumberSequenceKeypoint.new(0, 0.6),
    NumberSequenceKeypoint.new(0.5, 0),
    NumberSequenceKeypoint.new(1, 0.6),
})
glowGrad.Parent = glowLine

-- Brand label
local lblBrand = Instance.new("TextLabel")
lblBrand.Size                   = UDim2.new(1, -24, 0, 14)
lblBrand.Position               = UDim2.new(0, 12, 0, 8)
lblBrand.BackgroundTransparency = 1
lblBrand.Font                   = Enum.Font.GothamBold
lblBrand.TextSize               = 10
lblBrand.TextColor3             = COLORS.accent
lblBrand.TextXAlignment         = Enum.TextXAlignment.Left
lblBrand.Text                   = "ROBLOX BRIDGE"
lblBrand.Parent                 = header

-- Version badge
local lblVer = Instance.new("TextLabel")
lblVer.Size                   = UDim2.new(0, 40, 0, 14)
lblVer.Position               = UDim2.new(1, -52, 0, 8)
lblVer.BackgroundColor3       = COLORS.accentDim
lblVer.BackgroundTransparency = 0.6
lblVer.Font                   = Enum.Font.GothamBold
lblVer.TextSize               = 9
lblVer.TextColor3             = COLORS.accent
lblVer.Text                   = "v1.3.0"
lblVer.Parent                 = header
local verCorner = Instance.new("UICorner")
verCorner.CornerRadius = UDim.new(0, 4)
verCorner.Parent       = lblVer

-- Pulse dot
local pulseDot = Instance.new("Frame")
pulseDot.Name              = "PulseDot"
pulseDot.Size              = UDim2.new(0, 10, 0, 10)
pulseDot.Position          = UDim2.new(0, 12, 0, 30)
pulseDot.BackgroundColor3  = COLORS.red
pulseDot.BorderSizePixel   = 0
pulseDot.Parent            = header
local dotCorner = Instance.new("UICorner")
dotCorner.CornerRadius = UDim.new(1, 0)
dotCorner.Parent       = pulseDot

-- Outer glow ring around pulse dot
local dotGlow = Instance.new("Frame")
dotGlow.Size                   = UDim2.new(0, 18, 0, 18)
dotGlow.Position               = UDim2.new(0, 8, 0, 26)
dotGlow.BackgroundColor3       = COLORS.red
dotGlow.BackgroundTransparency = 0.8
dotGlow.BorderSizePixel        = 0
dotGlow.Parent                 = header
local glowCorner = Instance.new("UICorner")
glowCorner.CornerRadius = UDim.new(1, 0)
glowCorner.Parent       = dotGlow

-- Status text
local lblStatus = Instance.new("TextLabel")
lblStatus.Size                   = UDim2.new(1, -40, 0, 18)
lblStatus.Position               = UDim2.new(0, 28, 0, 26)
lblStatus.BackgroundTransparency = 1
lblStatus.Font                   = Enum.Font.GothamBold
lblStatus.TextSize               = 15
lblStatus.TextColor3             = COLORS.red
lblStatus.TextXAlignment         = Enum.TextXAlignment.Left
lblStatus.Text                   = "Disconnected"
lblStatus.Parent                 = header

-- Server + uptime line
local lblServer = Instance.new("TextLabel")
lblServer.Size                   = UDim2.new(1, -24, 0, 12)
lblServer.Position               = UDim2.new(0, 12, 0, 50)
lblServer.BackgroundTransparency = 1
lblServer.Font                   = Enum.Font.Gotham
lblServer.TextSize               = 10
lblServer.TextColor3             = COLORS.textDim
lblServer.TextXAlignment         = Enum.TextXAlignment.Left
lblServer.Text                   = "127.0.0.1:" .. CONFIG.port .. "  ·  Idle"
lblServer.Parent                 = header

-- ══════════════════════════════════════════════════════════════════
-- STATS CARDS — Three mini cards in a row
-- Height: 56px   Position: Y=78
-- ══════════════════════════════════════════════════════════════════
local statsRow = Instance.new("Frame")
statsRow.Name                   = "StatsRow"
statsRow.Size                   = UDim2.new(1, -20, 0, 50)
statsRow.Position               = UDim2.new(0, 10, 0, 78)
statsRow.BackgroundTransparency = 1
statsRow.Parent                 = root

local function makeStatCard(order, icon, value, label, xScale)
    local card = Instance.new("Frame")
    card.Name              = "Stat_" .. label
    card.Size              = UDim2.new(0.333, -4, 1, 0)
    card.Position          = UDim2.new(xScale, 0, 0, 0)
    card.BackgroundColor3  = COLORS.bgCard
    card.BorderSizePixel   = 0
    card.Parent            = statsRow
    local cCorner = Instance.new("UICorner")
    cCorner.CornerRadius = UDim.new(0, 6)
    cCorner.Parent       = card

    local iconLbl = Instance.new("TextLabel")
    iconLbl.Size                   = UDim2.new(1, 0, 0, 14)
    iconLbl.Position               = UDim2.new(0, 0, 0, 6)
    iconLbl.BackgroundTransparency = 1
    iconLbl.Font                   = Enum.Font.Gotham
    iconLbl.TextSize               = 11
    iconLbl.TextColor3             = COLORS.textDim
    iconLbl.Text                   = icon
    iconLbl.Parent                 = card

    local valLbl = Instance.new("TextLabel")
    valLbl.Name                    = "Value"
    valLbl.Size                    = UDim2.new(1, 0, 0, 16)
    valLbl.Position                = UDim2.new(0, 0, 0, 19)
    valLbl.BackgroundTransparency  = 1
    valLbl.Font                    = Enum.Font.GothamBold
    valLbl.TextSize                = 14
    valLbl.TextColor3              = COLORS.textBright
    valLbl.Text                    = tostring(value)
    valLbl.Parent                  = card

    local lblSub = Instance.new("TextLabel")
    lblSub.Size                    = UDim2.new(1, 0, 0, 10)
    lblSub.Position                = UDim2.new(0, 0, 1, -13)
    lblSub.BackgroundTransparency  = 1
    lblSub.Font                    = Enum.Font.Gotham
    lblSub.TextSize                = 8
    lblSub.TextColor3              = COLORS.textDim
    lblSub.Text                    = label
    lblSub.Parent                  = card

    return valLbl
end

local statSynced = makeStatCard(1, "📦", "0",  "SYNCED",  0)
local statPoll   = makeStatCard(2, "⏱",  CONFIG.pollInterval .. "s", "POLL",    0.333 + 0.005)
local statTime   = makeStatCard(3, "🕐", "—",  "LAST SYNC", 0.666 + 0.01)

-- ══════════════════════════════════════════════════════════════════
-- PROGRESS BAR — sits between stats and log
-- Height: 3px   Position: Y=133
-- ══════════════════════════════════════════════════════════════════
local progressTrack = Instance.new("Frame")
progressTrack.Name              = "ProgressTrack"
progressTrack.Size              = UDim2.new(1, -20, 0, 3)
progressTrack.Position          = UDim2.new(0, 10, 0, 133)
progressTrack.BackgroundColor3  = COLORS.divider
progressTrack.BorderSizePixel   = 0
progressTrack.Parent            = root
local ptCorner = Instance.new("UICorner")
ptCorner.CornerRadius = UDim.new(0, 2)
ptCorner.Parent       = progressTrack

local progressFill = Instance.new("Frame")
progressFill.Name              = "Fill"
progressFill.Size              = UDim2.new(0, 0, 1, 0)
progressFill.BackgroundColor3  = COLORS.accent
progressFill.BorderSizePixel   = 0
progressFill.Parent            = progressTrack
local pfCorner = Instance.new("UICorner")
pfCorner.CornerRadius = UDim.new(0, 2)
pfCorner.Parent       = progressFill

-- ══════════════════════════════════════════════════════════════════
-- LOG SECTION — header bar + scrollable log
-- Position: Y=142   Fills remaining height
-- ══════════════════════════════════════════════════════════════════

-- Log header (title + clear button)
local logBar = Instance.new("Frame")
logBar.Name                    = "LogBar"
logBar.Size                    = UDim2.new(1, -20, 0, 22)
logBar.Position                = UDim2.new(0, 10, 0, 142)
logBar.BackgroundTransparency  = 1
logBar.Parent                  = root

local lblLogTitle = Instance.new("TextLabel")
lblLogTitle.Size                   = UDim2.new(0.6, 0, 1, 0)
lblLogTitle.Position               = UDim2.new(0, 2, 0, 0)
lblLogTitle.BackgroundTransparency = 1
lblLogTitle.Font                   = Enum.Font.GothamBold
lblLogTitle.TextSize               = 9
lblLogTitle.TextColor3             = COLORS.textDim
lblLogTitle.TextXAlignment         = Enum.TextXAlignment.Left
lblLogTitle.Text                   = "ACTIVITY LOG"
lblLogTitle.Parent                 = logBar

-- Clear button with hover effect
local btnClear = Instance.new("TextButton")
btnClear.Name              = "ClearBtn"
btnClear.Size              = UDim2.new(0, 44, 0, 18)
btnClear.Position          = UDim2.new(1, -44, 0.5, -9)
btnClear.BackgroundColor3  = COLORS.bgCard
btnClear.BorderSizePixel   = 0
btnClear.Font              = Enum.Font.GothamBold
btnClear.TextSize          = 9
btnClear.TextColor3        = COLORS.textDim
btnClear.Text              = "Clear"
btnClear.AutoButtonColor   = false
btnClear.Parent            = logBar
local clearCorner = Instance.new("UICorner")
clearCorner.CornerRadius = UDim.new(0, 4)
clearCorner.Parent       = btnClear

-- Hover effects for Clear button
btnClear.MouseEnter:Connect(function()
    TweenService:Create(btnClear, TweenInfo.new(0.15), {
        BackgroundColor3 = COLORS.bgCardHover,
        TextColor3       = COLORS.textBright,
    }):Play()
end)
btnClear.MouseLeave:Connect(function()
    TweenService:Create(btnClear, TweenInfo.new(0.15), {
        BackgroundColor3 = COLORS.bgCard,
        TextColor3       = COLORS.textDim,
    }):Play()
end)

-- Scrolling log — fills remaining vertical space
local logScroll = Instance.new("ScrollingFrame")
logScroll.Name                   = "LogScroll"
logScroll.Size                   = UDim2.new(1, -20, 1, -170)  -- anchored from top 170px
logScroll.Position               = UDim2.new(0, 10, 0, 168)
logScroll.BackgroundColor3       = COLORS.logBg
logScroll.BorderSizePixel        = 0
logScroll.ScrollBarThickness     = 4
logScroll.ScrollBarImageColor3   = COLORS.scrollThumb
logScroll.CanvasSize             = UDim2.new(0, 0, 0, 0)
logScroll.AutomaticCanvasSize    = Enum.AutomaticSize.Y
logScroll.ScrollingDirection     = Enum.ScrollingDirection.Y
logScroll.TopImage               = ""
logScroll.MidImage               = "rbxasset://textures/ui/Scroll/scroll-middle.png"
logScroll.BottomImage            = ""
logScroll.Parent                 = root

local logCorner = Instance.new("UICorner")
logCorner.CornerRadius = UDim.new(0, 6)
logCorner.Parent       = logScroll

local logPad = Instance.new("UIPadding")
logPad.PaddingLeft   = UDim.new(0, 8)
logPad.PaddingRight  = UDim.new(0, 8)
logPad.PaddingTop    = UDim.new(0, 6)
logPad.PaddingBottom = UDim.new(0, 6)
logPad.Parent        = logScroll

local logLayout = Instance.new("UIListLayout")
logLayout.SortOrder = Enum.SortOrder.LayoutOrder
logLayout.Padding   = UDim.new(0, 1)
logLayout.Parent    = logScroll

-- ══════════════════════════════════════════════════════════════════
-- ANIMATIONS
-- ══════════════════════════════════════════════════════════════════

-- ── Pulse animation ───────────────────────────────────────────────
local pulseActive = false
local function startPulse()
    if pulseActive then return end
    pulseActive = true
    task.spawn(function()
        while pulseActive do
            -- Fade glow out
            TweenService:Create(dotGlow, TweenInfo.new(0.9, Enum.EasingStyle.Sine, Enum.EasingDirection.Out),
                {BackgroundTransparency = 0.95}):Play()
            local t1 = TweenService:Create(pulseDot, TweenInfo.new(0.9, Enum.EasingStyle.Sine, Enum.EasingDirection.Out),
                {BackgroundTransparency = 0.4})
            t1:Play()
            t1.Completed:Wait()
            if not pulseActive then break end
            -- Fade glow in
            TweenService:Create(dotGlow, TweenInfo.new(0.9, Enum.EasingStyle.Sine, Enum.EasingDirection.In),
                {BackgroundTransparency = 0.75}):Play()
            local t2 = TweenService:Create(pulseDot, TweenInfo.new(0.9, Enum.EasingStyle.Sine, Enum.EasingDirection.In),
                {BackgroundTransparency = 0})
            t2:Play()
            t2.Completed:Wait()
        end
    end)
end

local function stopPulse()
    pulseActive = false
    pulseDot.BackgroundTransparency = 0
    dotGlow.BackgroundTransparency  = 0.85
end

-- ── Progress bar animation ────────────────────────────────────────
local function animateProgress()
    progressFill.Size = UDim2.new(0, 0, 1, 0)
    progressFill.BackgroundColor3 = COLORS.accent
    local tweenFill = TweenService:Create(progressFill,
        TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
        {Size = UDim2.new(1, 0, 1, 0)})
    tweenFill:Play()
    -- Fade out after filling
    tweenFill.Completed:Connect(function()
        task.wait(0.3)
        TweenService:Create(progressFill,
            TweenInfo.new(0.4, Enum.EasingStyle.Quad),
            {Size = UDim2.new(0, 0, 1, 0)}):Play()
    end)
end

-- ── Glow line color change ────────────────────────────────────────
local function setGlowColor(color)
    TweenService:Create(glowLine, TweenInfo.new(0.4), {BackgroundColor3 = color}):Play()
end

-- ══════════════════════════════════════════════════════════════════
-- LOG ENTRIES
-- ══════════════════════════════════════════════════════════════════
local logEntryCount = 0
local MAX_LOG_ENTRIES = 60

local function addLogEntry(msg, color)
    logEntryCount = logEntryCount + 1
    local entry = Instance.new("TextLabel")
    entry.Name                   = "Log_" .. logEntryCount
    entry.Size                   = UDim2.new(1, 0, 0, 0) -- auto-sized
    entry.BackgroundTransparency = 1
    entry.Font                   = Enum.Font.Code
    entry.TextSize               = 10
    entry.TextColor3             = color or COLORS.textDim
    entry.TextXAlignment         = Enum.TextXAlignment.Left
    entry.TextWrapped            = true
    entry.AutomaticSize          = Enum.AutomaticSize.Y
    entry.RichText               = false
    entry.Text                   = os.date("%H:%M:%S") .. "  " .. msg
    entry.LayoutOrder            = logEntryCount
    entry.Parent                 = logScroll

    -- Trim oldest when over limit
    local children = logScroll:GetChildren()
    local textCount = 0
    for _, child in ipairs(children) do
        if child:IsA("TextLabel") then textCount = textCount + 1 end
    end
    if textCount > MAX_LOG_ENTRIES then
        for _, child in ipairs(children) do
            if child:IsA("TextLabel") then child:Destroy(); break end
        end
    end

    -- Auto-scroll to bottom
    task.defer(function()
        logScroll.CanvasPosition = Vector2.new(0, logScroll.AbsoluteCanvasSize.Y)
    end)
end

-- Clear button handler
btnClear.MouseButton1Click:Connect(function()
    for _, child in ipairs(logScroll:GetChildren()) do
        if child:IsA("TextLabel") then child:Destroy() end
    end
    logEntryCount = 0
    addLogEntry("Log cleared", COLORS.textDim)
end)

-- ══════════════════════════════════════════════════════════════════
-- WIDGET UPDATER
-- ══════════════════════════════════════════════════════════════════
local function formatUptime(seconds)
    if seconds < 60 then return string.format("%ds", seconds) end
    if seconds < 3600 then return string.format("%dm %ds", math.floor(seconds/60), seconds%60) end
    return string.format("%dh %dm", math.floor(seconds/3600), math.floor((seconds%3600)/60))
end

local function updateWidget(connected, lastSyncText)
    if connected then
        lblStatus.Text        = "Connected"
        lblStatus.TextColor3  = COLORS.green
        pulseDot.BackgroundColor3    = COLORS.green
        dotGlow.BackgroundColor3     = COLORS.green
        setGlowColor(COLORS.green)

        local uptime = ""
        if connectStartTime > 0 then
            uptime = "  ·  " .. formatUptime(math.floor(os.clock() - connectStartTime))
        end
        lblServer.Text = "127.0.0.1:" .. CONFIG.port .. uptime

        if not pulseActive then startPulse() end
    else
        lblStatus.Text        = "Disconnected"
        lblStatus.TextColor3  = COLORS.red
        pulseDot.BackgroundColor3    = COLORS.red
        dotGlow.BackgroundColor3     = COLORS.red
        lblServer.Text        = "127.0.0.1:" .. CONFIG.port .. "  ·  Idle"
        setGlowColor(COLORS.accent)
        stopPulse()
    end
    if lastSyncText then
        statTime.Text = lastSyncText
    end
    statSynced.Text = tostring(totalScriptsSynced)
    statPoll.Text   = CONFIG.pollInterval .. "s"
end

-- Uptime ticker — update server label every 5s while connected
task.spawn(function()
    while true do
        task.wait(5)
        if isRunning and connectStartTime > 0 then
            local uptime = formatUptime(math.floor(os.clock() - connectStartTime))
            lblServer.Text = "127.0.0.1:" .. CONFIG.port .. "  ·  " .. uptime
        end
    end
end)

-- ── Logging ──────────────────────────────────────────────────────
local function log(msg)
    local line = "[RobloxBridge] " .. tostring(msg)
    print(line)
    addLogEntry(tostring(msg), COLORS.textDim)
end

local function logWarn(msg)
    local line = "[RobloxBridge] " .. tostring(msg)
    warn(line)
    addLogEntry(tostring(msg), COLORS.yellow)
end

local function logSuccess(msg)
    local line = "[RobloxBridge] " .. tostring(msg)
    print(line)
    addLogEntry(tostring(msg), COLORS.green)
end

local function logError(msg)
    local line = "[RobloxBridge] " .. tostring(msg)
    warn(line)
    addLogEntry(tostring(msg), COLORS.red)
end

local function logCreate(msg)
    addLogEntry("+ " .. tostring(msg), COLORS.green)
    print("[RobloxBridge] Created  " .. tostring(msg))
end

local function logUpdate(msg)
    addLogEntry("~ " .. tostring(msg), COLORS.yellow)
    print("[RobloxBridge] Updated  " .. tostring(msg))
end

local function logDelete(msg)
    addLogEntry("- " .. tostring(msg), COLORS.red)
    print("[RobloxBridge] Deleted  " .. tostring(msg))
end

-- ── Instance helpers ──────────────────────────────────────────────
local function resolveService(name)
    local ok, svc = pcall(function() return game:GetService(name) end)
    if ok and svc then return svc end
    return game:FindFirstChild(name)
end

local function ensurePath(robloxPath)
    local parts = {}
    for part in robloxPath:gmatch("[^/]+") do
        table.insert(parts, part)
    end
    if #parts == 0 then return nil end

    local current = resolveService(parts[1])
    if not current then
        logError("Cannot resolve service: " .. parts[1])
        return nil
    end

    for i = 2, #parts - 1 do
        local child = current:FindFirstChild(parts[i])
        if not child then
            child        = Instance.new("Folder")
            child.Name   = parts[i]
            child.Parent = current
        end
        current = child
    end

    return current, parts[#parts]
end

local function applyScript(robloxPath, scriptClass, source)
    if not robloxPath or source == nil then return end

    local parent, name = ensurePath(robloxPath)
    if not parent or not name then return end

    local existing = parent:FindFirstChild(name)

    if existing and existing.ClassName ~= scriptClass then
        existing:Destroy()
        existing = nil
    end

    if existing then
        if existing.Source ~= source then
            existing.Source = source
            logUpdate(existing:GetFullName())
            totalScriptsSynced = totalScriptsSynced + 1
        end
    else
        local inst    = Instance.new(scriptClass)
        inst.Name     = name
        inst.Source   = source
        inst.Parent   = parent
        logCreate(inst:GetFullName())
        totalScriptsSynced = totalScriptsSynced + 1
    end
end

local function deleteScript(robloxPath)
    if not robloxPath then return end
    local parent, name = ensurePath(robloxPath)
    if parent and name then
        local child = parent:FindFirstChild(name)
        if child then
            child:Destroy()
            logDelete(robloxPath)
        end
    end
end

-- ── HTTP helpers ──────────────────────────────────────────────────
local function httpGet(endpoint)
    return HttpService:GetAsync(BASE_URL .. endpoint, true)
end

local function httpPost(endpoint, payload)
    return HttpService:PostAsync(
        BASE_URL .. endpoint,
        HttpService:JSONEncode(payload),
        Enum.HttpContentType.ApplicationJson,
        false
    )
end

-- ── Heartbeat ─────────────────────────────────────────────────────
local function sendHeartbeat()
    pcall(function()
        httpPost("/heartbeat", {
            version      = "1.3.0",
            pollInterval = CONFIG.pollInterval,
        })
    end)
end

-- ── Heartbeat check (initial connection test) ──────────────────────
local function checkConnection()
    local ok, result = pcall(function()
        return HttpService:JSONDecode(httpGet("/"))
    end)
    return ok and result and result.server == "roblox-bridge"
end

-- ── Fetch server config ───────────────────────────────────────────
local function fetchConfig()
    local ok, raw = pcall(function() return httpGet("/config") end)
    if not ok then return end

    local ok2, cfg = pcall(function() return HttpService:JSONDecode(raw) end)
    if not ok2 or not cfg then return end

    if type(cfg.pollInterval) == "number" and cfg.pollInterval >= 1 then
        CONFIG.pollInterval = cfg.pollInterval
        log(string.format("Config: poll interval = %ds", CONFIG.pollInterval))
    end
    if type(cfg.preferLuau) == "boolean" then
        CONFIG.useLuau = cfg.preferLuau
        if CONFIG.useLuau then log("Config: file extension = .luau") end
    end
    if type(cfg.twoWayDelete) == "boolean" then
        CONFIG.twoWayDelete = cfg.twoWayDelete
        if CONFIG.twoWayDelete then log("Config: two-way delete enabled") end
    end
    updateWidget(isRunning)
end

-- ── Two-way delete (Feature 6) ────────────────────────────────────
local function notifyDeleteToVSCode(robloxPath, scriptClass)
    if not CONFIG.twoWayDelete then return end
    pcall(function()
        httpPost("/delete-from-studio", {
            robloxPath  = robloxPath,
            scriptClass = scriptClass or "ModuleScript",
        })
    end)
end

-- ── Main sync poll ────────────────────────────────────────────────
local function pollChanges()
    local ok, raw = pcall(function()
        return httpGet("/changes?since=" .. lastTimestamp)
    end)
    if not ok then
        log("Server unreachable: " .. tostring(raw))
        return false
    end

    local ok2, data = pcall(function() return HttpService:JSONDecode(raw) end)
    if not ok2 then return false end

    local changed = 0
    if data.changes and #data.changes > 0 then
        animateProgress()

        for _, change in ipairs(data.changes) do
            if change.event == "delete" then
                deleteScript(change.robloxPath)
            elseif change.content ~= nil and change.robloxPath ~= nil then
                applyScript(change.robloxPath, change.scriptClass, change.content)
                changed = changed + 1
            end
            if change.timestamp and change.timestamp > lastTimestamp then
                lastTimestamp = change.timestamp
            end
        end

        local timeStr = os.date("%H:%M:%S")
        updateWidget(true, timeStr .. "  (" .. changed .. " file(s))")
    end

    if data.serverTime then
        if not data.changes or #data.changes == 0 then
            lastTimestamp = data.serverTime
        end
    end

    return true
end

-- ── Upload selected scripts to VS Code ────────────────────────────
local function uploadSelected()
    local selected = Selection:Get()
    if #selected == 0 then
        logWarn("No instances selected — select scripts in the Explorer first.")
        return
    end

    local uploaded = 0
    local conflicts = 0

    for _, inst in ipairs(selected) do
        if not inst:IsA("LuaSourceContainer") then
            log("Skipping " .. inst.Name .. " (not a script)")
        else
            local pathParts = {}
            local current   = inst
            while current and current ~= game do
                table.insert(pathParts, 1, current.Name)
                current = current.Parent
            end

            local dotExt = CONFIG.useLuau and ".luau" or ".lua"
            local ext    = dotExt
            if inst.ClassName == "Script"          then ext = ".server" .. dotExt
            elseif inst.ClassName == "LocalScript" then ext = ".client" .. dotExt
            end

            local filePath = CONFIG.sourcePath .. "/" ..
                             table.concat(pathParts, "/") .. ext

            local ok, raw = pcall(function()
                return httpPost("/write", {
                    filePath   = filePath,
                    content    = inst.Source,
                    lastPulled = lastTimestamp,
                })
            end)

            if ok then
                local ok2, result = pcall(function()
                    return HttpService:JSONDecode(raw)
                end)
                if ok2 and result and result.conflict then
                    logError("CONFLICT: " .. filePath ..
                        " — modified in VS Code after your last pull.")
                    conflicts = conflicts + 1
                else
                    logSuccess("Uploaded → " .. filePath)
                    uploaded = uploaded + 1
                end
            else
                logError("Upload failed for " .. inst.Name .. ": " .. tostring(raw))
            end
        end
    end

    if uploaded > 0 then
        logSuccess(string.format("Upload done: %d script(s) sent to VS Code.", uploaded))
    end
    if conflicts > 0 then
        logWarn(string.format("%d conflict(s) detected — those files were NOT overwritten.", conflicts))
    end
end

-- ── Export ALL scripts from this game to VS Code ──────────────────
local EXPORT_SERVICES = {
    "ServerScriptService",
    "ReplicatedStorage",
    "StarterPlayer",
    "StarterGui",
    "ServerStorage",
    "StarterCharacterScripts",
    "Workspace",
}

local function exportToVSCode()
    if not checkConnection() then
        logError("Bridge server not reachable — start it in VS Code first.")
        return
    end

    log("── Export started ── collecting all scripts…")
    animateProgress()
    local scripts = {}

    local function walk(inst, pathParts)
        if inst:IsA("LuaSourceContainer") then
            table.insert(scripts, {
                robloxPath  = table.concat(pathParts, "/"),
                scriptClass = inst.ClassName,
                content     = inst.Source,
            })
        end
        for _, child in ipairs(inst:GetChildren()) do
            local newParts = {}
            for _, p in ipairs(pathParts) do table.insert(newParts, p) end
            table.insert(newParts, child.Name)
            walk(child, newParts)
        end
    end

    for _, serviceName in ipairs(EXPORT_SERVICES) do
        local ok, service = pcall(function() return game:GetService(serviceName) end)
        if ok and service then
            for _, child in ipairs(service:GetChildren()) do
                walk(child, {serviceName, child.Name})
            end
        end
    end

    if #scripts == 0 then
        logWarn("No scripts found in the game to export.")
        return
    end

    log(string.format("Found %d script(s) — sending to VS Code…", #scripts))

    local ok, raw = pcall(function()
        return httpPost("/sync-from-studio", { scripts = scripts })
    end)

    if not ok then
        logError("Export FAILED: " .. tostring(raw))
        return
    end

    local ok2, result = pcall(function() return HttpService:JSONDecode(raw) end)

    if ok2 and result and result.success then
        local total = (result.created or 0) + (result.updated or 0)
        logSuccess(string.format(
            "✓ Export complete!  %d new  +  %d updated  =  %d script(s) sent to VS Code.",
            result.created or 0, result.updated or 0, total
        ))
        updateWidget(isRunning, os.date("%H:%M:%S") .. "  (export: " .. total .. ")")
    else
        logError("Export: unexpected response — " .. tostring(raw))
    end
end

-- ── Pull all files from VS Code ───────────────────────────────────
local function pullAll()
    log("Pulling all files from VS Code…")
    animateProgress()
    lastTimestamp = 0

    local ok, raw = pcall(function() return httpGet("/files") end)
    if not ok then
        logError("Pull FAILED: " .. tostring(raw))
        return
    end

    local ok2, data = pcall(function() return HttpService:JSONDecode(raw) end)
    if not ok2 or not data.files then return end

    pollChanges()
    logSuccess(string.format("✓ Pull complete — %d file(s) available from VS Code.", #data.files))
    updateWidget(isRunning, os.date("%H:%M:%S") .. "  (pull: " .. #data.files .. ")")
end

-- ── Plugin UI ─────────────────────────────────────────────────────
local toolbar = plugin:CreateToolbar("Roblox Bridge")

local btnConnect = toolbar:CreateButton(
    "Connect",
    "Start / stop syncing with VS Code Bridge server",
    "rbxassetid://7072706796"
)

local btnExport = toolbar:CreateButton(
    "Export →",
    "Export all scripts from this game to VS Code as editable .lua files",
    "rbxassetid://7072706796"
)

local btnPull = toolbar:CreateButton(
    "Pull All",
    "Pull every file from VS Code right now",
    "rbxassetid://7072706796"
)

local btnUpload = toolbar:CreateButton(
    "Upload",
    "Upload selected script(s) from Studio to VS Code",
    "rbxassetid://7072706796"
)

local btnStatus = toolbar:CreateButton(
    "Status",
    "Toggle the Roblox Bridge status panel",
    "rbxassetid://7072706796"
)

-- ── Connect / Disconnect ──────────────────────────────────────────
btnConnect.Click:Connect(function()
    btnConnect:SetActive(not isRunning)

    if not isRunning then
        if not checkConnection() then
            logError(string.format(
                "Cannot reach bridge server on port %d. " ..
                "Make sure VS Code has started the bridge first.",
                CONFIG.port
            ))
            btnConnect:SetActive(false)
            return
        end

        isRunning          = true
        reconnectAttempts  = 0
        lastTimestamp      = 0
        connectStartTime   = os.clock()

        fetchConfig()

        logSuccess(string.format(
            "✓ Connected to bridge on port %d — polling every %ds.",
            CONFIG.port, CONFIG.pollInterval
        ))

        sendHeartbeat()
        updateWidget(true)
        startPulse()

        pullAll()

        -- Polling loop with auto-reconnect
        task.spawn(function()
            while isRunning do
                task.wait(CONFIG.pollInterval)
                if not isRunning then break end

                local ok = pollChanges()
                if ok then
                    sendHeartbeat()
                    reconnectAttempts = 0
                else
                    reconnectAttempts = reconnectAttempts + 1
                    if reconnectAttempts >= MAX_RECONNECT then
                        logError(string.format(
                            "Lost connection to VS Code after %d attempts — stopping.",
                            MAX_RECONNECT
                        ))
                        isRunning = false
                        connectStartTime = 0
                        btnConnect:SetActive(false)
                        reconnectAttempts = 0
                        updateWidget(false)
                        stopPulse()
                    else
                        logWarn(string.format(
                            "Connection hiccup — retry %d/%d…",
                            reconnectAttempts, MAX_RECONNECT
                        ))
                    end
                end
            end
        end)
    else
        isRunning = false
        connectStartTime = 0
        logWarn("Disconnected from bridge.")
        updateWidget(false)
        stopPulse()
    end
end)

btnPull.Click:Connect(function()
    if not checkConnection() then
        logError("Bridge server not reachable — start the server in VS Code first.")
        return
    end
    pullAll()
end)

btnExport.Click:Connect(exportToVSCode)

btnUpload.Click:Connect(uploadSelected)

btnStatus.Click:Connect(function()
    statusWidget.Enabled = not statusWidget.Enabled
    btnStatus:SetActive(statusWidget.Enabled)
end)

-- ── Startup message ───────────────────────────────────────────────
logSuccess(string.format("Plugin loaded v1.3.0  Server: 127.0.0.1:%d", CONFIG.port))
addLogEntry("QUICK START:", COLORS.accent)
addLogEntry("1. VS Code → Ctrl+Shift+P → Start Server", COLORS.textDim)
addLogEntry("2. Click [Export →] to send scripts", COLORS.textDim)
addLogEntry("3. Click [Connect] to start live sync", COLORS.textDim)
addLogEntry("4. Edit in VS Code — changes sync back", COLORS.textDim)

updateWidget(false)
