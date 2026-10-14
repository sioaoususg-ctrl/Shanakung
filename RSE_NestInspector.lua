-- language: Lua (Roblox exploit), file: RSE_NestInspector.lua
-- game: Ride & Steal Eggs  PlaceId: 15448459363
-- features: egg ESP, nest scanner, income display, boss bypass, auto-steal
-- Key attr format: "PetName|Variant||Income(M/hr)|Level"
-- SellEggs zone: Vector3(36.2353, 0.705646, -36.6103)  radius 7.97
-- NestPhase attr on Workspace  |  EggName/Kg/Mutation/LockedUntil on Egg parts
-- PenPets: Key attr encodes income; Income unit = M/hr (inferred from leaderboard scale)

-- ============================================================
-- SERVICES
-- ============================================================
local Players         = game:GetService("Players")
local RunService      = game:GetService("RunService")
local TweenService    = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local lp  = Players.LocalPlayer
local char, hrp, humanoid

local function refreshCharRefs()
    char     = lp.Character
    hrp      = char and char:FindFirstChild("HumanoidRootPart")
    humanoid = char and char:FindFirstChildOfClass("Humanoid")
end
refreshCharRefs()
lp.CharacterAdded:Connect(function(c)
    char = c
    hrp      = c:WaitForChild("HumanoidRootPart")
    humanoid = c:WaitForChild("Humanoid")
end)

-- ============================================================
-- CONSTANTS
-- ============================================================
local SELL_CENTER = Vector3.new(36.2353, 3, -36.6103)
local SELL_HEIGHT = 3   -- studs above ground to land at

local COLOR = {
    bg      = Color3.fromRGB(11, 11, 24),
    panel   = Color3.fromRGB(18, 28, 52),
    accent  = Color3.fromRGB(78, 204, 163),
    red     = Color3.fromRGB(233, 69, 96),
    gold    = Color3.fromRGB(255, 210, 50),
    blue    = Color3.fromRGB(80, 150, 255),
    purple  = Color3.fromRGB(160, 80, 255),
    orange  = Color3.fromRGB(255, 160, 40),
    dim     = Color3.fromRGB(120, 130, 160),
    white   = Color3.fromRGB(230, 235, 255),
    title   = Color3.fromRGB(15, 52, 96),
}

local VARIANT_COLOR = {
    Normal   = Color3.fromRGB(190, 195, 210),
    Gold     = Color3.fromRGB(255, 210, 50),
    Diamond  = Color3.fromRGB(130, 225, 255),
    Rainbow  = Color3.fromRGB(255, 100, 220),
    Demon    = Color3.fromRGB(210, 60, 60),
}

-- ============================================================
-- STATE
-- ============================================================
local state = {
    invincible  = false,
    noclip      = false,
    freezeBoss  = false,
    autoSteal   = false,
    espEnabled  = false,
    speed       = 16,
}

local espBillboards   = {}
local frozenParts     = {}
local autoStealActive = false

-- ============================================================
-- HELPERS
-- ============================================================
local function variantColor(v)
    return VARIANT_COLOR[v] or COLOR.dim
end

local function mutationColor(m)
    if m == "Gold"    then return COLOR.gold
    elseif m == "Rainbow" then return Color3.fromRGB(255, 100, 220)
    elseif m == "Diamond" then return Color3.fromRGB(130, 225, 255)
    else return COLOR.dim end
end

local function fmtIncome(v)
    if not v or v == 0 then return "—" end
    if v >= 1000 then return string.format("%.2fB/hr", v/1000)
    else              return string.format("%.2fM/hr", v) end
end

local function parseKey(key)
    -- "PetName|Variant||Income|Level"
    local p = string.split(key, "|")
    return {
        petName = p[1] or "?",
        variant = p[2] or "Normal",
        mutation= p[3] or "",
        income  = tonumber(p[4]) or 0,
        level   = tonumber(p[5]) or 0,
    }
end

local function corner(r, parent)
    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(0, r)
    c.Parent = parent
    return c
end

local function stroke(color, thick, parent)
    local s = Instance.new("UIStroke")
    s.Color = color
    s.Thickness = thick
    s.Parent = parent
    return s
end

local function label(text, size, font, color, parent)
    local l = Instance.new("TextLabel")
    l.BackgroundTransparency = 1
    l.Text = text
    l.TextSize = size
    l.Font = font or Enum.Font.Gotham
    l.TextColor3 = color or COLOR.white
    l.TextXAlignment = Enum.TextXAlignment.Left
    l.TextYAlignment = Enum.TextYAlignment.Center
    l.RichText = false
    l.ZIndex = 55
    l.Parent = parent
    return l
end

-- draggable mixin
local function makeDraggable(handle, target)
    local dragging, startInput, startPos = false, nil, nil
    handle.InputBegan:Connect(function(inp)
        if inp.UserInputType == Enum.UserInputType.MouseButton1
        or inp.UserInputType == Enum.UserInputType.Touch then
            dragging   = true
            startInput = inp.Position
            startPos   = target.Position
        end
    end)
    handle.InputChanged:Connect(function(inp)
        if dragging and (inp.UserInputType == Enum.UserInputType.MouseMovement
            or inp.UserInputType == Enum.UserInputType.Touch) then
            local delta = inp.Position - startInput
            target.Position = UDim2.new(
                startPos.X.Scale, startPos.X.Offset + delta.X,
                startPos.Y.Scale, startPos.Y.Offset + delta.Y
            )
        end
    end)
    handle.InputEnded:Connect(function(inp)
        if inp.UserInputType == Enum.UserInputType.MouseButton1
        or inp.UserInputType == Enum.UserInputType.Touch then
            dragging = false
        end
    end)
    return handle
end

-- ============================================================
-- GUI ROOT
-- ============================================================
-- destroy previous instance if script re-run
if lp.PlayerGui:FindFirstChild("RSE_NestGUI") then
    lp.PlayerGui.RSE_NestGUI:Destroy()
end

local GUI = Instance.new("ScreenGui")
GUI.Name             = "RSE_NestGUI"
GUI.ResetOnSpawn     = false
GUI.ZIndexBehavior   = Enum.ZIndexBehavior.Sibling
GUI.IgnoreGuiInset   = true
GUI.DisplayOrder     = 999
GUI.Parent           = lp.PlayerGui

-- ============================================================
-- FLOATING TOGGLE BUTTON
-- ============================================================
local ToggleBtn = Instance.new("TextButton")
ToggleBtn.Name             = "ToggleBtn"
ToggleBtn.Size             = UDim2.new(0, 58, 0, 58)
ToggleBtn.Position         = UDim2.new(1, -76, 0, 130)
ToggleBtn.BackgroundColor3 = COLOR.title
ToggleBtn.Text             = "🥚"
ToggleBtn.TextSize         = 30
ToggleBtn.Font             = Enum.Font.GothamBold
ToggleBtn.TextColor3       = COLOR.white
ToggleBtn.BorderSizePixel  = 0
ToggleBtn.ZIndex           = 200
ToggleBtn.Parent           = GUI
corner(14, ToggleBtn)
stroke(COLOR.accent, 2, ToggleBtn)
makeDraggable(ToggleBtn, ToggleBtn)

-- ============================================================
-- MAIN PANEL
-- ============================================================
local MainFrame = Instance.new("Frame")
MainFrame.Name             = "MainFrame"
MainFrame.Size             = UDim2.new(0, 318, 0, 490)
MainFrame.Position         = UDim2.new(1, 10, 0.5, -245)  -- off-screen start
MainFrame.BackgroundColor3 = COLOR.bg
MainFrame.BorderSizePixel  = 0
MainFrame.Visible          = false
MainFrame.ZIndex           = 100
MainFrame.Parent           = GUI
corner(16, MainFrame)
stroke(COLOR.accent, 1.5, MainFrame)

-- TITLE BAR
local TitleBar = Instance.new("Frame")
TitleBar.Name             = "TitleBar"
TitleBar.Size             = UDim2.new(1, 0, 0, 48)
TitleBar.BackgroundColor3 = COLOR.title
TitleBar.BorderSizePixel  = 0
TitleBar.ZIndex           = 101
TitleBar.Parent           = MainFrame
corner(16, TitleBar)
-- mask bottom-round of title bar
local TitleMask = Instance.new("Frame")
TitleMask.Size             = UDim2.new(1, 0, 0, 16)
TitleMask.Position         = UDim2.new(0, 0, 1, -16)
TitleMask.BackgroundColor3 = COLOR.title
TitleMask.BorderSizePixel  = 0
TitleMask.ZIndex           = 101
TitleMask.Parent           = TitleBar

local TitleLabel = label("🥚  Nest Inspector", 17, Enum.Font.GothamBold, COLOR.accent, TitleBar)
TitleLabel.Size     = UDim2.new(1, -54, 1, 0)
TitleLabel.Position = UDim2.new(0, 14, 0, 0)
TitleLabel.ZIndex   = 102

local CloseBtn = Instance.new("TextButton")
CloseBtn.Size             = UDim2.new(0, 32, 0, 32)
CloseBtn.Position         = UDim2.new(1, -44, 0.5, -16)
CloseBtn.BackgroundColor3 = COLOR.red
CloseBtn.Text             = "✕"
CloseBtn.TextColor3       = COLOR.white
CloseBtn.TextSize         = 15
CloseBtn.Font             = Enum.Font.GothamBold
CloseBtn.BorderSizePixel  = 0
CloseBtn.ZIndex           = 102
CloseBtn.Parent           = TitleBar
corner(8, CloseBtn)
makeDraggable(TitleBar, MainFrame)

-- TAB BAR
local TabBar = Instance.new("Frame")
TabBar.Name             = "TabBar"
TabBar.Size             = UDim2.new(1, 0, 0, 42)
TabBar.Position         = UDim2.new(0, 0, 0, 48)
TabBar.BackgroundColor3 = Color3.fromRGB(14, 14, 30)
TabBar.BorderSizePixel  = 0
TabBar.ZIndex           = 101
TabBar.Parent           = MainFrame
local TabLayout = Instance.new("UIListLayout")
TabLayout.FillDirection      = Enum.FillDirection.Horizontal
TabLayout.Padding            = UDim.new(0, 1)
TabLayout.VerticalAlignment  = Enum.VerticalAlignment.Center
TabLayout.HorizontalAlignment= Enum.HorizontalAlignment.Center
TabLayout.Parent             = TabBar

-- SCROLL CONTENT
local ScrollFrame = Instance.new("ScrollingFrame")
ScrollFrame.Name                = "ScrollFrame"
ScrollFrame.Size                = UDim2.new(1, 0, 1, -90)
ScrollFrame.Position            = UDim2.new(0, 0, 0, 90)
ScrollFrame.BackgroundTransparency = 1
ScrollFrame.BorderSizePixel     = 0
ScrollFrame.ScrollBarThickness  = 4
ScrollFrame.ScrollBarImageColor3= COLOR.accent
ScrollFrame.CanvasSize          = UDim2.new(0, 0, 0, 0)
ScrollFrame.AutomaticCanvasSize = Enum.AutomaticSize.Y
ScrollFrame.ZIndex              = 101
ScrollFrame.Parent              = MainFrame

local ScrollLayout = Instance.new("UIListLayout")
ScrollLayout.Padding            = UDim.new(0, 6)
ScrollLayout.SortOrder          = Enum.SortOrder.LayoutOrder
ScrollLayout.Parent             = ScrollFrame

local ScrollPad = Instance.new("UIPadding")
ScrollPad.PaddingTop   = UDim.new(0, 8)
ScrollPad.PaddingLeft  = UDim.new(0, 8)
ScrollPad.PaddingRight = UDim.new(0, 8)
ScrollPad.Parent       = ScrollFrame

-- ============================================================
-- TAB SYSTEM
-- ============================================================
local tabButtons  = {}
local tabContents = {}

local tabDefs = {
    { name="Nests",  icon="📍" },
    { name="Bases",  icon="🏠" },
    { name="Bypass", icon="⚔️" },
    { name="Steal",  icon="🏃" },
}

local function setActiveTab(name)
    for k, btn in pairs(tabButtons) do
        local active = (k == name)
        btn.BackgroundColor3 = active and COLOR.title or Color3.fromRGB(14, 14, 30)
        btn.TextColor3       = active and COLOR.accent or COLOR.dim
    end
    for k, cont in pairs(tabContents) do
        cont.Visible = (k == name)
    end
end

local function makeTabBtn(def)
    local btn = Instance.new("TextButton")
    btn.Name             = def.name
    btn.Size             = UDim2.new(0.25, -2, 1, -6)
    btn.BackgroundColor3 = Color3.fromRGB(14, 14, 30)
    btn.Text             = def.icon.."\n"..def.name
    btn.TextColor3       = COLOR.dim
    btn.TextSize         = 11
    btn.Font             = Enum.Font.Gotham
    btn.BorderSizePixel  = 0
    btn.ZIndex           = 102
    btn.Parent           = TabBar
    corner(8, btn)
    tabButtons[def.name] = btn
    btn.MouseButton1Click:Connect(function() setActiveTab(def.name) end)
end

local function makeTabContent(name)
    local frame = Instance.new("Frame")
    frame.Name               = name.."Content"
    frame.BackgroundTransparency = 1
    frame.Size               = UDim2.new(1, 0, 0, 0)
    frame.AutomaticSize      = Enum.AutomaticSize.Y
    frame.Visible            = false
    frame.ZIndex             = 102
    frame.Parent             = ScrollFrame
    local fl = Instance.new("UIListLayout")
    fl.Padding  = UDim.new(0, 6)
    fl.SortOrder= Enum.SortOrder.LayoutOrder
    fl.Parent   = frame
    tabContents[name] = frame
    return frame
end

for _, def in ipairs(tabDefs) do
    makeTabBtn(def)
    makeTabContent(def.name)
end
setActiveTab("Nests")

-- ============================================================
-- CARD FACTORIES
-- ============================================================

local function sectionLabel(text, parent, order)
    local l = label("  "..text, 12, Enum.Font.GothamBold, COLOR.accent, parent)
    l.Size         = UDim2.new(1, 0, 0, 22)
    l.LayoutOrder  = order or 0
    l.ZIndex       = 103
    return l
end

-- Simple action button
local function actionBtn(txt, bgCol, txCol, parent, order)
    local btn = Instance.new("TextButton")
    btn.Size             = UDim2.new(1, 0, 0, 40)
    btn.BackgroundColor3 = bgCol
    btn.Text             = txt
    btn.TextColor3       = txCol
    btn.TextSize         = 13
    btn.Font             = Enum.Font.GothamBold
    btn.BorderSizePixel  = 0
    btn.ZIndex           = 103
    btn.LayoutOrder      = order or 0
    btn.Parent           = parent
    corner(10, btn)
    return btn
end

-- Toggle card  ─ returns (card, toggle_button)
local function toggleCard(labelTxt, subTxt, stateKey, onColor, parent, order)
    local card = Instance.new("Frame")
    card.Size             = UDim2.new(1, 0, 0, 56)
    card.BackgroundColor3 = COLOR.panel
    card.BorderSizePixel  = 0
    card.ZIndex           = 103
    card.LayoutOrder      = order or 0
    card.Parent           = parent
    corner(10, card)

    local lbl = label(labelTxt, 13, Enum.Font.GothamBold, COLOR.white, card)
    lbl.Size     = UDim2.new(1, -68, 0, 20)
    lbl.Position = UDim2.new(0, 10, 0, 8)
    lbl.ZIndex   = 104

    local sub = label(subTxt, 10, Enum.Font.Gotham, COLOR.dim, card)
    sub.Size     = UDim2.new(1, -68, 0, 16)
    sub.Position = UDim2.new(0, 10, 0, 30)
    sub.ZIndex   = 104

    local togBtn = Instance.new("TextButton")
    togBtn.Size             = UDim2.new(0, 50, 0, 26)
    togBtn.Position         = UDim2.new(1, -62, 0.5, -13)
    togBtn.BackgroundColor3 = Color3.fromRGB(55, 55, 75)
    togBtn.Text             = "OFF"
    togBtn.TextColor3       = COLOR.dim
    togBtn.TextSize         = 11
    togBtn.Font             = Enum.Font.GothamBold
    togBtn.BorderSizePixel  = 0
    togBtn.ZIndex           = 104
    togBtn.Parent           = card
    corner(13, togBtn)

    local function refresh()
        if state[stateKey] then
            togBtn.BackgroundColor3 = onColor
            togBtn.Text      = "ON"
            togBtn.TextColor3= COLOR.white
        else
            togBtn.BackgroundColor3 = Color3.fromRGB(55, 55, 75)
            togBtn.Text      = "OFF"
            togBtn.TextColor3= COLOR.dim
        end
    end
    togBtn.MouseButton1Click:Connect(function()
        state[stateKey] = not state[stateKey]
        refresh()
    end)
    refresh()
    return card, togBtn
end

-- Egg card for Nests tab
local function eggCard(eggName, kg, mutation, biome, nestName, pos, lockedUntil, parent, order)
    local locked = lockedUntil and (lockedUntil > os.time()) or false
    local card = Instance.new("Frame")
    card.Size             = UDim2.new(1, 0, 0, 74)
    card.BackgroundColor3 = Color3.fromRGB(14, 22, 40)
    card.BorderSizePixel  = 0
    card.ZIndex           = 103
    card.LayoutOrder      = order or 0
    card.Parent           = parent
    corner(10, card)
    stroke(mutationColor(mutation), 1, card)

    local nameL = label("🥚 "..eggName, 14, Enum.Font.GothamBold, COLOR.white, card)
    nameL.Size     = UDim2.new(0.58, 0, 0, 20)
    nameL.Position = UDim2.new(0, 10, 0, 6)
    nameL.ZIndex   = 104

    local mutL = label("✨ "..mutation, 11, Enum.Font.GothamBold, mutationColor(mutation), card)
    mutL.Size             = UDim2.new(0.38, 0, 0, 20)
    mutL.Position         = UDim2.new(0.62, -4, 0, 7)
    mutL.TextXAlignment   = Enum.TextXAlignment.Right
    mutL.ZIndex           = 104

    local infoL = label(string.format("⚖️ %.2f kg  🌿 %s · %s", kg, biome, nestName), 10, Enum.Font.Gotham, COLOR.dim, card)
    infoL.Size     = UDim2.new(1, -20, 0, 16)
    infoL.Position = UDim2.new(0, 10, 0, 28)
    infoL.ZIndex   = 104

    local lockL = label(locked and "🔒 Locked" or "🔓 Available", 11, Enum.Font.GothamBold,
        locked and COLOR.red or COLOR.accent, card)
    lockL.Size     = UDim2.new(0.5, 0, 0, 16)
    lockL.Position = UDim2.new(0, 10, 0, 48)
    lockL.ZIndex   = 104

    local tpBtn = Instance.new("TextButton")
    tpBtn.Size             = UDim2.new(0, 56, 0, 22)
    tpBtn.Position         = UDim2.new(1, -66, 0, 46)
    tpBtn.BackgroundColor3 = COLOR.title
    tpBtn.Text             = "📍 TP"
    tpBtn.TextColor3       = COLOR.accent
    tpBtn.TextSize         = 11
    tpBtn.Font             = Enum.Font.GothamBold
    tpBtn.BorderSizePixel  = 0
    tpBtn.ZIndex           = 104
    tpBtn.Parent           = card
    corner(6, tpBtn)
    tpBtn.MouseButton1Click:Connect(function()
        if char and hrp then
            hrp.CFrame = CFrame.new(pos + Vector3.new(0, 5, 0))
        end
    end)

    return card
end

-- Pet income card
local function petCard(petName, variant, income, level, ownerName, baseNum, parent, order)
    local card = Instance.new("Frame")
    card.Size             = UDim2.new(1, 0, 0, 66)
    card.BackgroundColor3 = Color3.fromRGB(14, 22, 40)
    card.BorderSizePixel  = 0
    card.ZIndex           = 103
    card.LayoutOrder      = order or 0
    card.Parent           = parent
    corner(10, card)
    stroke(variantColor(variant), 1, card)

    local nameL = label("🐾 "..petName, 13, Enum.Font.GothamBold, COLOR.white, card)
    nameL.Size     = UDim2.new(0.62, 0, 0, 20)
    nameL.Position = UDim2.new(0, 10, 0, 6)
    nameL.ZIndex   = 104

    local varL = label(variant, 11, Enum.Font.GothamBold, variantColor(variant), card)
    varL.Size           = UDim2.new(0.35, 0, 0, 18)
    varL.Position       = UDim2.new(0.65, -6, 0, 7)
    varL.TextXAlignment = Enum.TextXAlignment.Right
    varL.ZIndex         = 104

    local incL = label("💰 "..fmtIncome(income), 12, Enum.Font.GothamBold, COLOR.gold, card)
    incL.Size     = UDim2.new(0.55, 0, 0, 16)
    incL.Position = UDim2.new(0, 10, 0, 28)
    incL.ZIndex   = 104

    local lvlL = label("Lv."..level.."  Base "..baseNum, 10, Enum.Font.Gotham, COLOR.dim, card)
    lvlL.Size           = UDim2.new(0.45, 0, 0, 16)
    lvlL.Position       = UDim2.new(0.55, -4, 0, 29)
    lvlL.TextXAlignment = Enum.TextXAlignment.Right
    lvlL.ZIndex         = 104

    local ownL = label("👤 "..ownerName, 10, Enum.Font.Gotham, COLOR.dim, card)
    ownL.Size     = UDim2.new(1, -20, 0, 14)
    ownL.Position = UDim2.new(0, 10, 0, 48)
    ownL.ZIndex   = 104

    return card
end

-- ============================================================
-- NESTS TAB
-- ============================================================
local nestsTab = tabContents["Nests"]

sectionLabel("🌍 World Egg Scanner", nestsTab, 1)

local nestStatusL = label("Tap Refresh to scan", 11, Enum.Font.Gotham, COLOR.dim, nestsTab)
nestStatusL.Size        = UDim2.new(1, 0, 0, 18)
nestStatusL.LayoutOrder = 2
nestStatusL.ZIndex      = 103

local refreshNestsBtn = actionBtn("🔄 Refresh Nests", COLOR.title, COLOR.accent, nestsTab, 3)
local espCard, _      = toggleCard("🔭 Egg ESP", "Billboard above every nest egg", "espEnabled", COLOR.blue, nestsTab, 4)

local nestsListFrame = Instance.new("Frame")
nestsListFrame.BackgroundTransparency = 1
nestsListFrame.Size         = UDim2.new(1, 0, 0, 0)
nestsListFrame.AutomaticSize= Enum.AutomaticSize.Y
nestsListFrame.LayoutOrder  = 5
nestsListFrame.ZIndex       = 103
nestsListFrame.Parent       = nestsTab
local nfl = Instance.new("UIListLayout")
nfl.Padding   = UDim.new(0, 5)
nfl.SortOrder = Enum.SortOrder.LayoutOrder
nfl.Parent    = nestsListFrame

local function clearNestCards()
    for _, c in pairs(nestsListFrame:GetChildren()) do
        if not c:IsA("UIListLayout") then c:Destroy() end
    end
end

local function scanNests()
    clearNestCards()
    nestStatusL.Text = "Scanning..."

    local map    = workspace:FindFirstChild("Map")
    local biomes = map and map:FindFirstChild("Biomes")
    if not biomes then nestStatusL.Text = "Map/Biomes not found"; return end

    local count, order = 0, 0
    for _, biome in pairs(biomes:GetChildren()) do
        local nests = biome:FindFirstChild("Nests")
        if nests then
            for _, nest in pairs(nests:GetChildren()) do
                local egg = nest:FindFirstChild("Egg")
                if egg then
                    order = order + 1
                    eggCard(
                        egg:GetAttribute("EggName")    or "?",
                        egg:GetAttribute("Kg")          or 0,
                        egg:GetAttribute("Mutation")    or "Normal",
                        biome.Name,
                        nest.Name,
                        egg.Position,
                        egg:GetAttribute("LockedUntil"),
                        nestsListFrame, order
                    )
                    count = count + 1
                end
            end
        end
    end
    nestStatusL.Text = count.." egg(s) found"
end

refreshNestsBtn.MouseButton1Click:Connect(scanNests)

-- ESP billboard helpers
local function buildESP()
    for _, bb in pairs(espBillboards) do
        if bb and bb.Parent then bb:Destroy() end
    end
    espBillboards = {}
    local map    = workspace:FindFirstChild("Map")
    local biomes = map and map:FindFirstChild("Biomes")
    if not biomes then return end
    for _, biome in pairs(biomes:GetChildren()) do
        local nests = biome:FindFirstChild("Nests")
        if nests then
            for _, nest in pairs(nests:GetChildren()) do
                local egg = nest:FindFirstChild("Egg")
                if egg and egg:IsA("BasePart") then
                    local bb = Instance.new("BillboardGui")
                    bb.Size         = UDim2.new(0, 130, 0, 52)
                    bb.StudsOffset  = Vector3.new(0, 5, 0)
                    bb.AlwaysOnTop  = true
                    bb.Parent       = egg

                    local bg = Instance.new("Frame")
                    bg.Size             = UDim2.new(1, 0, 1, 0)
                    bg.BackgroundColor3 = Color3.fromRGB(8, 16, 36)
                    bg.BackgroundTransparency = 0.15
                    bg.BorderSizePixel  = 0
                    bg.Parent           = bb
                    corner(8, bg)
                    stroke(mutationColor(egg:GetAttribute("Mutation") or "Normal"), 1, bg)

                    local en = egg:GetAttribute("EggName") or "?"
                    local kg = egg:GetAttribute("Kg")      or 0
                    local mt = egg:GetAttribute("Mutation") or "Normal"

                    local n1 = label("🥚 "..en, 13, Enum.Font.GothamBold, COLOR.white, bg)
                    n1.Size     = UDim2.new(1, -6, 0.5, 0)
                    n1.Position = UDim2.new(0, 4, 0, 2)

                    local n2 = label(string.format("%.2fkg · %s", kg, mt), 10, Enum.Font.Gotham,
                        mutationColor(mt), bg)
                    n2.Size     = UDim2.new(1, -6, 0.5, 0)
                    n2.Position = UDim2.new(0, 4, 0.5, 0)

                    table.insert(espBillboards, bb)
                end
            end
        end
    end
end

local function clearESP()
    for _, bb in pairs(espBillboards) do
        if bb and bb.Parent then bb:Destroy() end
    end
    espBillboards = {}
end

-- wire ESP toggle's ON callback
do
    local espToggle = espCard:FindFirstChildOfClass("TextButton")
    espToggle.MouseButton1Click:Connect(function()
        if state.espEnabled then buildESP() else clearESP() end
    end)
end

-- ============================================================
-- BASES TAB
-- ============================================================
local basesTab = tabContents["Bases"]

sectionLabel("🐾 All Pen Pets (Income)", basesTab, 1)

local totalIncomeL = label("💰 Total: —", 13, Enum.Font.GothamBold, COLOR.gold, basesTab)
totalIncomeL.Size        = UDim2.new(1, 0, 0, 22)
totalIncomeL.LayoutOrder = 2
totalIncomeL.ZIndex      = 103

local refreshBasesBtn = actionBtn("🔄 Scan Pets", COLOR.title, COLOR.accent, basesTab, 3)

local basesListFrame = Instance.new("Frame")
basesListFrame.BackgroundTransparency = 1
basesListFrame.Size         = UDim2.new(1, 0, 0, 0)
basesListFrame.AutomaticSize= Enum.AutomaticSize.Y
basesListFrame.LayoutOrder  = 4
basesListFrame.ZIndex       = 103
basesListFrame.Parent       = basesTab
local bfl = Instance.new("UIListLayout")
bfl.Padding   = UDim.new(0, 5)
bfl.SortOrder = Enum.SortOrder.LayoutOrder
bfl.Parent    = basesListFrame

local function clearBaseCards()
    for _, c in pairs(basesListFrame:GetChildren()) do
        if not c:IsA("UIListLayout") then c:Destroy() end
    end
end

local function scanBases()
    clearBaseCards()
    local map   = workspace:FindFirstChild("Map")
    local bases = map and map:FindFirstChild("Bases")
    if not bases then return end

    local allPets = {}
    local total   = 0
    for _, base in pairs(bases:GetChildren()) do
        local pen = base:FindFirstChild("PenPets")
        if pen then
            local ownerId   = base:GetAttribute("OwnerId")
            local pl        = ownerId and Players:GetPlayerByUserId(ownerId)
            local ownerName = pl and pl.Name or (ownerId and "ID:"..tostring(ownerId) or "?")
            local baseNum   = base.Name:gsub("Base", "")
            for _, pet in pairs(pen:GetChildren()) do
                local key = pet:GetAttribute("Key")
                if key then
                    local d = parseKey(key)
                    total = total + d.income
                    table.insert(allPets, {
                        petName  = d.petName,
                        variant  = d.variant,
                        income   = d.income,
                        level    = d.level,
                        ownerName= ownerName,
                        baseNum  = baseNum,
                    })
                end
            end
        end
    end

    table.sort(allPets, function(a, b) return a.income > b.income end)
    totalIncomeL.Text = "💰 Total: "..fmtIncome(total)

    for i, d in ipairs(allPets) do
        petCard(d.petName, d.variant, d.income, d.level, d.ownerName, d.baseNum, basesListFrame, i)
    end
end

refreshBasesBtn.MouseButton1Click:Connect(scanBases)

-- ============================================================
-- BYPASS TAB
-- ============================================================
local bypassTab = tabContents["Bypass"]

sectionLabel("⚔️ Boss Bypass", bypassTab, 1)

local invCard, _   = toggleCard("💛 Invincibility",     "Heartbeat-lock health to max",          "invincible",  COLOR.accent, bypassTab, 2)
local ncCard, _    = toggleCard("👻 NoClip",             "Phase through all BaseParts",           "noclip",      COLOR.blue,   bypassTab, 3)
local frCard, _    = toggleCard("🧊 Freeze Guardians",   "Anchor all enemy PenPets locally",      "freezeBoss",  COLOR.red,    bypassTab, 4)

sectionLabel("🚀 Speed", bypassTab, 5)

local speedFrame = Instance.new("Frame")
speedFrame.Size             = UDim2.new(1, 0, 0, 62)
speedFrame.BackgroundColor3 = COLOR.panel
speedFrame.BorderSizePixel  = 0
speedFrame.LayoutOrder      = 6
speedFrame.ZIndex           = 103
speedFrame.Parent           = bypassTab
corner(10, speedFrame)

local speedLbl = label("⚡ WalkSpeed: 16", 13, Enum.Font.GothamBold, COLOR.white, speedFrame)
speedLbl.Size     = UDim2.new(1, -12, 0, 22)
speedLbl.Position = UDim2.new(0, 10, 0, 5)
speedLbl.ZIndex   = 104

local speedBtns = Instance.new("Frame")
speedBtns.Size             = UDim2.new(1, -20, 0, 28)
speedBtns.Position         = UDim2.new(0, 10, 0, 30)
speedBtns.BackgroundTransparency = 1
speedBtns.ZIndex           = 104
speedBtns.Parent           = speedFrame
local sbLayout = Instance.new("UIListLayout")
sbLayout.FillDirection = Enum.FillDirection.Horizontal
sbLayout.Padding       = UDim.new(0, 4)
sbLayout.Parent        = speedBtns

local speeds = {16, 50, 100, 200, 500}
for _, spd in ipairs(speeds) do
    local sb = Instance.new("TextButton")
    sb.Size             = UDim2.new(0, 46, 1, 0)
    sb.BackgroundColor3 = COLOR.title
    sb.Text             = tostring(spd)
    sb.TextColor3       = COLOR.accent
    sb.TextSize         = 11
    sb.Font             = Enum.Font.GothamBold
    sb.BorderSizePixel  = 0
    sb.ZIndex           = 105
    sb.Parent           = speedBtns
    corner(6, sb)
    sb.MouseButton1Click:Connect(function()
        state.speed = spd
        speedLbl.Text = "⚡ WalkSpeed: "..spd
        if humanoid then humanoid.WalkSpeed = spd end
    end)
end

-- freeze logic implementation
local function applyFreezeGuardians(on)
    -- unfreeze any previously anchored parts
    for _, part in pairs(frozenParts) do
        if part and part.Parent then
            part.Anchored = false
        end
    end
    frozenParts = {}
    if not on then return end

    local myId = lp.UserId
    local map  = workspace:FindFirstChild("Map")
    local bases= map and map:FindFirstChild("Bases")
    if not bases then return end
    for _, base in pairs(bases:GetChildren()) do
        local ownerId = base:GetAttribute("OwnerId")
        if ownerId and ownerId ~= myId then
            local pen = base:FindFirstChild("PenPets")
            if pen then
                for _, pet in pairs(pen:GetDescendants()) do
                    if pet:IsA("BasePart") then
                        pet.Anchored = true
                        table.insert(frozenParts, pet)
                    end
                end
            end
        end
    end
end

-- wire freeze toggle
do
    local ft = frCard:FindFirstChildOfClass("TextButton")
    ft.MouseButton1Click:Connect(function()
        applyFreezeGuardians(state.freezeBoss)
    end)
end

-- ============================================================
-- STEAL TAB
-- ============================================================
local stealTab = tabContents["Steal"]

sectionLabel("🏃 Steal Toolkit", stealTab, 1)

local stealInfoL = Instance.new("TextLabel")
stealInfoL.Size             = UDim2.new(1, 0, 0, 48)
stealInfoL.BackgroundColor3 = Color3.fromRGB(14, 28, 14)
stealInfoL.BackgroundTransparency = 0
stealInfoL.Text             = "Sell zone @ (36, -37) · ProximityPrompt fire\nUse Freeze+Noclip for clean run."
stealInfoL.TextColor3       = COLOR.dim
stealInfoL.TextSize         = 11
stealInfoL.Font             = Enum.Font.Gotham
stealInfoL.TextWrapped      = true
stealInfoL.BorderSizePixel  = 0
stealInfoL.ZIndex           = 103
stealInfoL.LayoutOrder      = 2
stealInfoL.Parent           = stealTab
corner(8, stealInfoL)

local autoCard, _ = toggleCard("🔄 Auto Steal Loop", "TP egg → fire prompt → sell  (2 s cycle)", "autoSteal", COLOR.orange, stealTab, 3)

local tpEggBtn  = actionBtn("📍 TP to Nearest Unlocked Egg", Color3.fromRGB(20, 55, 35), Color3.fromRGB(80, 255, 140), stealTab, 4)
local fireBtn   = actionBtn("👐 Fire ProximityPrompt (Grab)",  Color3.fromRGB(55, 40, 10), COLOR.gold,                   stealTab, 5)
local tpSellBtn = actionBtn("🚀 TP to Sell Zone",              Color3.fromRGB(45, 15, 65), Color3.fromRGB(200, 100, 255), stealTab, 6)

-- helpers
local function getNearestUnlockedEgg()
    if not char or not hrp then return nil end
    local myPos = hrp.Position
    local map   = workspace:FindFirstChild("Map")
    local biomes= map and map:FindFirstChild("Biomes")
    if not biomes then return nil end
    local best, bestDist = nil, math.huge
    for _, biome in pairs(biomes:GetChildren()) do
        local nests = biome:FindFirstChild("Nests")
        if nests then
            for _, nest in pairs(nests:GetChildren()) do
                local egg = nest:FindFirstChild("Egg")
                if egg then
                    local lu = egg:GetAttribute("LockedUntil")
                    if not lu or lu <= os.time() then
                        local d = (egg.Position - myPos).Magnitude
                        if d < bestDist then
                            bestDist, best = d, egg
                        end
                    end
                end
            end
        end
    end
    return best
end

local function fireEggPrompt(egg)
    if not egg then return end
    local prompt = egg:FindFirstChildOfClass("ProximityPrompt")
    if prompt then
        -- try exploit globals; both are standard in popular script executors
        local ok = pcall(fireproximityprompt, prompt)
        if not ok then
            pcall(fireclickdetector, prompt)
        end
    end
end

tpEggBtn.MouseButton1Click:Connect(function()
    local egg = getNearestUnlockedEgg()
    if egg and hrp then
        hrp.CFrame = CFrame.new(egg.Position + Vector3.new(0, 4, 2))
    end
end)

fireBtn.MouseButton1Click:Connect(function()
    local egg = getNearestUnlockedEgg()
    if not egg or not hrp then return end
    hrp.CFrame = CFrame.new(egg.Position + Vector3.new(0, 3, 1.5))
    task.wait(0.18)
    fireEggPrompt(egg)
end)

tpSellBtn.MouseButton1Click:Connect(function()
    if hrp then
        hrp.CFrame = CFrame.new(SELL_CENTER)
    end
end)

-- Auto steal loop
local function runAutoSteal()
    while state.autoSteal do
        local egg = getNearestUnlockedEgg()
        if egg and hrp then
            hrp.CFrame = CFrame.new(egg.Position + Vector3.new(0, 3, 1.5))
            task.wait(0.2)
            fireEggPrompt(egg)
            task.wait(0.4)
            hrp.CFrame = CFrame.new(SELL_CENTER)
        end
        task.wait(2)
    end
end

do
    local at = autoCard:FindFirstChildOfClass("TextButton")
    at.MouseButton1Click:Connect(function()
        if state.autoSteal then
            task.spawn(runAutoSteal)
        end
    end)
end

-- ============================================================
-- RUNSERVICE HEARTBEAT  ─ invincibility + noclip + speed sync
-- ============================================================
RunService.Heartbeat:Connect(function()
    if not char then return end

    -- invincibility
    if state.invincible then
        local h = char:FindFirstChildOfClass("Humanoid")
        if h then h.Health = h.MaxHealth end
    end

    -- noclip
    if state.noclip then
        for _, part in pairs(char:GetDescendants()) do
            if part:IsA("BasePart") then
                part.CanCollide = false
            end
        end
    end

    -- walkspeed sync (re-apply after respawn/server reset)
    if state.speed ~= 16 then
        local h = char:FindFirstChildOfClass("Humanoid")
        if h and math.abs(h.WalkSpeed - state.speed) > 0.5 then
            h.WalkSpeed = state.speed
        end
    end
end)

-- ============================================================
-- PANEL OPEN / CLOSE
-- ============================================================
local panelOpen = false
local OPEN_POS  = UDim2.new(1, -328, 0.5, -245)
local CLOSE_POS = UDim2.new(1,   12, 0.5, -245)

local function setPanel(open)
    panelOpen = open
    if open then
        MainFrame.Visible = true
        TweenService:Create(MainFrame, TweenInfo.new(0.25, Enum.EasingStyle.Quart, Enum.EasingDirection.Out), {
            Position = OPEN_POS
        }):Play()
    else
        local t = TweenService:Create(MainFrame, TweenInfo.new(0.2, Enum.EasingStyle.Quart, Enum.EasingDirection.In), {
            Position = CLOSE_POS
        })
        t:Play()
        t.Completed:Connect(function()
            if not panelOpen then MainFrame.Visible = false end
        end)
    end
end

-- toggle button: only fire if not dragging
local togDragging = false
ToggleBtn.InputBegan:Connect(function(inp)
    if inp.UserInputType == Enum.UserInputType.MouseButton1
    or inp.UserInputType == Enum.UserInputType.Touch then
        togDragging = false
    end
end)
ToggleBtn.InputChanged:Connect(function(inp)
    if inp.UserInputType == Enum.UserInputType.MouseMovement
    or inp.UserInputType == Enum.UserInputType.Touch then
        togDragging = true
    end
end)
ToggleBtn.MouseButton1Click:Connect(function()
    if not togDragging then setPanel(not panelOpen) end
end)
CloseBtn.MouseButton1Click:Connect(function() setPanel(false) end)

-- ============================================================
-- AUTO-SCAN ON FIRST OPEN
-- ============================================================
local firstOpen = true
local origSetPanel = setPanel
setPanel = function(open)
    if open and firstOpen then
        firstOpen = false
        task.defer(function()
            scanNests()
            scanBases()
        end)
    end
    origSetPanel(open)
end

print("[RSE NestInspector] loaded  ─  tap 🥚 to open")
