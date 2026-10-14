-- [[ RSE NestInspector v4 ]]
-- Game:    Ride & Steal Eggs  (PlaceId 15448459363)
-- Engine:  Roblox / Luau  |  macOS executor (e.g. Script-Ware M)
-- Fix v4:  scanNests() rewrote from scratch — eggs live in
--          workspace.Map.Biomes[biome].Nests[nest].Egg (Part)
--          Attributes: EggName(str), Kg(num), Mutation(str), LockedUntil(num|nil)
--          No Key/PetKey attr exists; old v3 always got "" → parseKey() → nil → 0 results.
--          New scan reads real attrs, sorts by Kg desc, shows biome + Mutation colour.
-- UI v4:   Wider panel, gradient title, pill badges, glow stroke, animated scan btn.

local Players    = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local lp   = Players.LocalPlayer
local char = lp.Character or lp.CharacterAdded:Wait()
local hrp  = char:WaitForChild("HumanoidRootPart")

-- ─── state ───────────────────────────────────────────────────────────────────
local state = { invincible=false, noclip=false, esp=false, stealing=false }
local frozenGuardians = {}
local espBillboards   = {}

-- ─── variant colours ─────────────────────────────────────────────────────────
local MUT_COLOR = {
    Normal  = Color3.fromRGB(210, 210, 220),
    Gold    = Color3.fromRGB(255, 210, 50),
    Diamond = Color3.fromRGB(90,  220, 255),
    Rainbow = Color3.fromRGB(255, 110, 255),
    Secret  = Color3.fromRGB(255, 70,  70),
}
local MUT_GLOW = {
    Normal  = Color3.fromRGB(60,  50,  90),
    Gold    = Color3.fromRGB(140, 100, 0),
    Diamond = Color3.fromRGB(0,   110, 180),
    Rainbow = Color3.fromRGB(150, 0,   180),
    Secret  = Color3.fromRGB(180, 0,   0),
}

-- ─── helpers ─────────────────────────────────────────────────────────────────
local function getPlayerBase()
    local bases = workspace:FindFirstChild("Map")
        and workspace.Map:FindFirstChild("Bases")
    if not bases then return nil end
    for _, b in ipairs(bases:GetChildren()) do
        if b:GetAttribute("OwnerId") == lp.UserId then return b end
    end
end

local function getBaseSpawnCF()
    local base = getPlayerBase()
    if base then
        local spawn = base:FindFirstChild("Spawn")
        if spawn and spawn:IsA("BasePart") then
            return spawn.CFrame + Vector3.new(0, 5, 0)
        end
        if base.PrimaryPart then
            return base.PrimaryPart.CFrame + Vector3.new(0, 6, 0)
        end
        for _, p in ipairs(base:GetDescendants()) do
            if p:IsA("BasePart") and p.Name ~= "HumanoidRootPart" then
                return p.CFrame + Vector3.new(0, 6, 0)
            end
        end
    end
    return CFrame.new(0, 10, 0)
end

-- ─── ride system ─────────────────────────────────────────────────────────────
local function getFastestOwnPet()
    local base = getPlayerBase()
    if not base then return nil end
    local pen = base:FindFirstChild("PenPets")
    if not pen then return nil end

    local best, bestScore = nil, -1
    for _, pet in ipairs(pen:GetChildren()) do
        if pet:GetAttribute("OwnerId") == lp.UserId then
            local hrpPet = pet:FindFirstChild("HumanoidRootPart")
            if hrpPet and hrpPet:FindFirstChild("RidePrompt") then
                local seatH = tonumber(pet:GetAttribute("SeatHeight")) or 0
                local score = seatH * 10
                if score > bestScore then
                    bestScore = score
                    best = {
                        model  = pet,
                        hrp    = hrpPet,
                        prompt = hrpPet:FindFirstChild("RidePrompt"),
                        name   = pet:GetAttribute("PetName") or pet.Name,
                        score  = score,
                    }
                end
            end
        end
    end
    return best
end

local function mountPet(petInfo)
    if not petInfo then return false end
    hrp.CFrame = petInfo.hrp.CFrame + Vector3.new(0, 3, 2)
    task.wait(0.15)
    pcall(fireproximityprompt, petInfo.prompt)
    task.wait(0.35)
    for _, obj in ipairs(char:GetDescendants()) do
        if obj.Name == "ShownPet" and obj:GetAttribute("Mode") == "Ride" then
            return true
        end
    end
    return false
end

-- ─── guardian freeze ─────────────────────────────────────────────────────────
local function freezeGuardian(biomeName)
    local biomes = workspace:FindFirstChild("Map")
        and workspace.Map:FindFirstChild("Biomes")
    if not biomes then return end
    local biomeF = biomes:FindFirstChild(biomeName)
    if not biomeF then return end
    local guardian = biomeF:FindFirstChild(biomeName .. "Guardian")
    if not guardian or frozenGuardians[guardian] then return end

    frozenGuardians[guardian] = {}
    for _, part in ipairs(guardian:GetDescendants()) do
        if part:IsA("BasePart") then
            local was = part.Anchored
            part.Anchored = true
            table.insert(frozenGuardians[guardian], {part=part, was=was})
        end
    end
end

local function unfreezeAll()
    for _, list in pairs(frozenGuardians) do
        for _, e in ipairs(list) do pcall(function() e.part.Anchored = e.was end) end
    end
    frozenGuardians = {}
end

-- ─── egg scan (v4 FIX) ───────────────────────────────────────────────────────
-- Real schema from dump:
--   workspace.Map.Biomes.[BiomeName].Nests.[NestName].Egg  (Part)
--   Attributes on Egg:
--     EggName   (string)  — e.g. "DesertEgg"
--     Kg        (number)  — weight = proxy for value
--     Mutation  (string)  — "Normal"|"Gold"|"Diamond"|"Rainbow"|"Secret"
--     Aura      (string)  — optional, same values
--     LockedUntil (number|nil) — tick() timestamp; nil or absent = available
--
-- The old v3 scanned for Key/PetKey which do NOT exist on biome eggs → always 0 results.
local function scanNests()
    local results = {}
    local biomes = workspace:FindFirstChild("Map")
        and workspace.Map:FindFirstChild("Biomes")
    if not biomes then return results end

    local now = tick()

    for _, biomeF in ipairs(biomes:GetChildren()) do
        local nestsF = biomeF:FindFirstChild("Nests")
        if nestsF then
            for _, nest in ipairs(nestsF:GetChildren()) do
                local egg = nest:FindFirstChild("Egg")
                if egg and egg:IsA("BasePart") then
                    -- lock check — nil means no lock (available)
                    local locked = egg:GetAttribute("LockedUntil")
                    local available = (not locked) or (locked <= now)

                    if available then
                        local eggName = egg:GetAttribute("EggName") or nest.Name
                        local kg      = tonumber(egg:GetAttribute("Kg")) or 0
                        local mut     = egg:GetAttribute("Mutation") or "Normal"
                        local aura    = egg:GetAttribute("Aura")    -- optional
                        -- Prefer Aura over Mutation for display if it's rarer
                        local displayMut = aura or mut

                        table.insert(results, {
                            biome   = biomeF.Name,
                            nest    = nest.Name,
                            egg     = egg,
                            eggName = eggName,
                            kg      = kg,
                            mutation = displayMut,
                        })
                    end
                end
            end
        end
    end

    -- Sort: rarest mutation first, then heaviest egg
    local mutOrder = { Secret=0, Rainbow=1, Diamond=2, Gold=3, Normal=4 }
    table.sort(results, function(a, b)
        local oa = mutOrder[a.mutation] or 4
        local ob = mutOrder[b.mutation] or 4
        if oa ~= ob then return oa < ob end
        return a.kg > b.kg
    end)
    return results
end

-- ─── full steal flow ─────────────────────────────────────────────────────────
local function stealEgg(entry, statusCb)
    if state.stealing then return end
    state.stealing = true
    local function upd(msg) if statusCb then statusCb(msg) end end

    upd("🐾 หาสัตว์เร็วสุด...")
    local petInfo = getFastestOwnPet()
    if petInfo then
        upd("🐾 ขึ้น " .. petInfo.name .. "...")
        mountPet(petInfo)
        task.wait(0.4)
        upd("🐾 ขึ้นสำเร็จ!")
    else
        upd("⚠️ ไม่เจอสัตว์ใน base — ไปเลย")
        task.wait(0.3)
    end

    upd("🧊 Freeze " .. entry.biome .. " Guardian...")
    freezeGuardian(entry.biome)
    task.wait(0.15)

    local eggPart = entry.egg
    if not eggPart or not eggPart.Parent then
        upd("❌ Egg หายแล้ว — abort")
        state.stealing = false; return
    end

    upd("🚀 TP → " .. entry.eggName .. "...")
    hrp.CFrame = eggPart.CFrame + Vector3.new(0, 3, 0)
    task.wait(0.25)

    upd("🥚 Fire steal prompt...")
    local prompt = eggPart:FindFirstChildWhichIsA("ProximityPrompt")
        or eggPart:FindFirstChildWhichIsA("ProximityPrompt", true)
    if prompt then
        pcall(fireproximityprompt, prompt)
        task.wait(0.4)
    else
        upd("⚠️ ไม่เจอ prompt — อาจต้อง TP ชิดกว่านี้")
        task.wait(0.4)
    end

    upd("🏠 กลับ base...")
    hrp.CFrame = getBaseSpawnCF()
    task.wait(0.15)

    upd("✅ Done — " .. entry.eggName .. " (" .. entry.mutation .. ")")
    state.stealing = false
end

-- ─── ESP ─────────────────────────────────────────────────────────────────────
local function buildESP()
    local nests = scanNests()
    for _, entry in ipairs(nests) do
        local egg = entry.egg
        if egg and egg.Parent and not espBillboards[egg] then
            local bb = Instance.new("BillboardGui")
            bb.Name = "RSE_ESP_v4"
            bb.AlwaysOnTop = true
            bb.Size = UDim2.new(0, 140, 0, 46)
            bb.StudsOffset = Vector3.new(0, 4, 0)
            bb.Adornee = egg; bb.Parent = egg

            local bg = Instance.new("Frame", bb)
            bg.Size = UDim2.fromScale(1,1)
            bg.BackgroundColor3 = Color3.fromRGB(10,8,20)
            bg.BackgroundTransparency = 0.25
            bg.BorderSizePixel = 0
            Instance.new("UICorner", bg).CornerRadius = UDim.new(0,8)
            local s = Instance.new("UIStroke", bg)
            s.Color = MUT_GLOW[entry.mutation] or MUT_GLOW.Normal
            s.Thickness = 1.5

            local tName = Instance.new("TextLabel", bg)
            tName.Size = UDim2.new(1,-6,0.52,0); tName.Position = UDim2.new(0,3,0,2)
            tName.BackgroundTransparency = 1
            tName.TextColor3 = MUT_COLOR[entry.mutation] or Color3.new(1,1,1)
            tName.TextScaled = true; tName.Font = Enum.Font.GothamBold
            tName.Text = entry.eggName

            local tSub = Instance.new("TextLabel", bg)
            tSub.Size = UDim2.new(1,-6,0.4,0); tSub.Position = UDim2.new(0,3,0.56,0)
            tSub.BackgroundTransparency = 1
            tSub.TextColor3 = Color3.fromRGB(160,240,140)
            tSub.TextScaled = true; tSub.Font = Enum.Font.Gotham
            tSub.Text = string.format("⚖️ %.2f kg  •  %s", entry.kg, entry.biome)

            espBillboards[egg] = bb
        end
    end
end

local function clearESP()
    for _, bb in pairs(espBillboards) do pcall(function() bb:Destroy() end) end
    espBillboards = {}
end

-- ─── invincibility / noclip ───────────────────────────────────────────────────
local invConn, noclipConn

local function startInvincible()
    if invConn then invConn:Disconnect() end
    invConn = RunService.Heartbeat:Connect(function()
        if not state.invincible then invConn:Disconnect(); invConn = nil; return end
        local h = char:FindFirstChildOfClass("Humanoid")
        if h then h.Health = h.MaxHealth end
    end)
end

local function startNoclip()
    if noclipConn then noclipConn:Disconnect() end
    noclipConn = RunService.Stepped:Connect(function()
        if not state.noclip then noclipConn:Disconnect(); noclipConn = nil; return end
        for _, p in ipairs(char:GetDescendants()) do
            if p:IsA("BasePart") then p.CanCollide = false end
        end
    end)
end

-- ═══════════════════════════════════════════════════════════════
--  UI  v4
-- ═══════════════════════════════════════════════════════════════
local gui = Instance.new("ScreenGui")
gui.Name = "RSENestInspector_v4"
gui.ResetOnSpawn = false
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent = (pcall(function() return gethui() end) and gethui()) or lp.PlayerGui

-- palette
local C = {
    bg       = Color3.fromRGB(10, 8, 20),
    panel    = Color3.fromRGB(15, 12, 28),
    titleBg  = Color3.fromRGB(22, 16, 44),
    accent   = Color3.fromRGB(130, 80, 230),
    accentDim= Color3.fromRGB(70,  42, 130),
    text     = Color3.fromRGB(215, 200, 255),
    subtext  = Color3.fromRGB(130, 115, 170),
    green    = Color3.fromRGB(120, 240, 140),
    stripBg  = Color3.fromRGB(20,  16,  38),
    cardBg   = Color3.fromRGB(18,  14,  34),
    sep      = Color3.fromRGB(48,  38,  80),
    stealBtn = Color3.fromRGB(150, 45,  215),
    stealHold= Color3.fromRGB(80,  22,  120),
    closeBg  = Color3.fromRGB(180, 40,  50),
}

-- main panel  290 × 420
local panel = Instance.new("Frame", gui)
panel.Name = "MainPanel"
panel.Size = UDim2.new(0, 290, 0, 420)
panel.Position = UDim2.new(0.5, -145, 0.5, -210)
panel.BackgroundColor3 = C.panel
panel.BorderSizePixel = 0
panel.Active = true
panel.Draggable = true
Instance.new("UICorner", panel).CornerRadius = UDim.new(0, 12)
do
    local s = Instance.new("UIStroke", panel)
    s.Color = C.accent; s.Thickness = 1.5
end

-- ── title bar ────────────────────────────────────────────────────
local titleBar = Instance.new("Frame", panel)
titleBar.Size = UDim2.new(1, 0, 0, 36)
titleBar.BackgroundColor3 = C.titleBg
titleBar.BorderSizePixel = 0
do
    local c = Instance.new("UICorner", titleBar); c.CornerRadius = UDim.new(0,12)
    -- square off bottom corners
    local fix = Instance.new("Frame", titleBar)
    fix.Size = UDim2.new(1,0,0.5,0); fix.Position = UDim2.new(0,0,0.5,0)
    fix.BackgroundColor3 = C.titleBg; fix.BorderSizePixel = 0
end

-- gradient on title bar
local tg = Instance.new("UIGradient", titleBar)
tg.Color = ColorSequence.new({
    ColorSequenceKeypoint.new(0, Color3.fromRGB(34,20,64)),
    ColorSequenceKeypoint.new(1, Color3.fromRGB(18,12,40)),
})
tg.Rotation = 90

local titleLbl = Instance.new("TextLabel", titleBar)
titleLbl.Size = UDim2.new(1,-44,1,0); titleLbl.Position = UDim2.new(0,12,0,0)
titleLbl.BackgroundTransparency = 1
titleLbl.TextColor3 = C.text
titleLbl.TextScaled = true; titleLbl.Font = Enum.Font.GothamBold
titleLbl.Text = "🥚  RSE NestInspector  v4"
titleLbl.TextXAlignment = Enum.TextXAlignment.Left

local closeBtn = Instance.new("TextButton", titleBar)
closeBtn.Size = UDim2.new(0,24,0,24); closeBtn.Position = UDim2.new(1,-28,0.5,-12)
closeBtn.BackgroundColor3 = C.closeBg; closeBtn.BorderSizePixel = 0
closeBtn.Text = "✕"; closeBtn.TextScaled = true; closeBtn.Font = Enum.Font.GothamBold
closeBtn.TextColor3 = Color3.new(1,1,1)
Instance.new("UICorner", closeBtn).CornerRadius = UDim.new(0,6)

-- ── section label ────────────────────────────────────────────────
local function makeSectionLabel(parent, yPos, txt)
    local lbl = Instance.new("TextLabel", parent)
    lbl.Size = UDim2.new(1,-16,0,16); lbl.Position = UDim2.new(0,8,0,yPos)
    lbl.BackgroundTransparency = 1
    lbl.TextColor3 = C.subtext
    lbl.TextScaled = true; lbl.Font = Enum.Font.GothamSemibold
    lbl.Text = txt; lbl.TextXAlignment = Enum.TextXAlignment.Left
    return lbl
end

makeSectionLabel(panel, 38, "⚔️  Bypass & Steal")

-- ── ride info strip ──────────────────────────────────────────────
local rideStrip = Instance.new("Frame", panel)
rideStrip.Size = UDim2.new(1,-16,0,22); rideStrip.Position = UDim2.new(0,8,0,56)
rideStrip.BackgroundColor3 = C.stripBg; rideStrip.BorderSizePixel = 0
Instance.new("UICorner", rideStrip).CornerRadius = UDim.new(0,6)

local rideLbl = Instance.new("TextLabel", rideStrip)
rideLbl.Size = UDim2.fromScale(1,1); rideLbl.BackgroundTransparency = 1
rideLbl.TextColor3 = C.green
rideLbl.TextScaled = true; rideLbl.Font = Enum.Font.Gotham
rideLbl.Text = "🐾 สัตว์เร็วสุด: กด Scan"

-- ── toggle row ───────────────────────────────────────────────────
local toggleRow = Instance.new("Frame", panel)
toggleRow.Size = UDim2.new(1,-16,0,28); toggleRow.Position = UDim2.new(0,8,0,81)
toggleRow.BackgroundTransparency = 1
do
    local l = Instance.new("UIListLayout", toggleRow)
    l.FillDirection = Enum.FillDirection.Horizontal
    l.Padding = UDim.new(0,6)
end

local function makeToggle(parent, lbl, key, cb)
    local btn = Instance.new("TextButton", parent)
    btn.Size = UDim2.new(0,80,1,0)
    btn.BackgroundColor3 = C.accentDim; btn.BorderSizePixel = 0
    btn.TextScaled = true; btn.Font = Enum.Font.GothamSemibold
    btn.TextColor3 = C.subtext
    btn.Text = lbl .. " OFF"
    Instance.new("UICorner", btn).CornerRadius = UDim.new(0,7)
    do
        local s = Instance.new("UIStroke", btn)
        s.Color = C.sep; s.Thickness = 1
    end
    btn.MouseButton1Click:Connect(function()
        state[key] = not state[key]
        if state[key] then
            btn.BackgroundColor3 = C.accent
            btn.TextColor3 = Color3.new(1,1,1)
            btn.Text = lbl .. " ON"
        else
            btn.BackgroundColor3 = C.accentDim
            btn.TextColor3 = C.subtext
            btn.Text = lbl .. " OFF"
        end
        if cb then cb(state[key]) end
    end)
    return btn
end

makeToggle(toggleRow,"Invinc","invincible",function(on) if on then startInvincible() end end)
makeToggle(toggleRow,"NoClip","noclip",    function(on) if on then startNoclip() end end)
makeToggle(toggleRow,"ESP","esp",          function(on) if on then buildESP() else clearESP() end end)

-- ── separator ────────────────────────────────────────────────────
local function makeSep(parent, yPos)
    local s = Instance.new("Frame", parent)
    s.Size = UDim2.new(1,-16,0,1); s.Position = UDim2.new(0,8,0,yPos)
    s.BackgroundColor3 = C.sep; s.BorderSizePixel = 0
    return s
end
makeSep(panel, 112)

-- ── status bar ───────────────────────────────────────────────────
local statusBar = Instance.new("Frame", panel)
statusBar.Size = UDim2.new(1,-16,0,24); statusBar.Position = UDim2.new(0,8,0,115)
statusBar.BackgroundColor3 = C.stripBg; statusBar.BorderSizePixel = 0
Instance.new("UICorner", statusBar).CornerRadius = UDim.new(0,6)

local statusLbl = Instance.new("TextLabel", statusBar)
statusLbl.Size = UDim2.new(1,-8,1,0); statusLbl.Position = UDim2.new(0,4,0,0)
statusLbl.BackgroundTransparency = 1
statusLbl.TextColor3 = C.text
statusLbl.TextScaled = true; statusLbl.Font = Enum.Font.Gotham
statusLbl.Text = "พร้อมใช้งาน — กด Scan"; statusLbl.TextXAlignment = Enum.TextXAlignment.Left

-- ── scan button ──────────────────────────────────────────────────
local scanBtn = Instance.new("TextButton", panel)
scanBtn.Size = UDim2.new(1,-16,0,28); scanBtn.Position = UDim2.new(0,8,0,142)
scanBtn.BackgroundColor3 = C.accent; scanBtn.BorderSizePixel = 0
scanBtn.TextScaled = true; scanBtn.Font = Enum.Font.GothamBold
scanBtn.TextColor3 = Color3.new(1,1,1)
scanBtn.Text = "🔍  Scan Nests"
Instance.new("UICorner", scanBtn).CornerRadius = UDim.new(0,8)
do
    local g = Instance.new("UIGradient", scanBtn)
    g.Color = ColorSequence.new({
        ColorSequenceKeypoint.new(0, Color3.fromRGB(170, 90, 255)),
        ColorSequenceKeypoint.new(1, Color3.fromRGB(110, 50, 200)),
    })
    g.Rotation = 90
end

makeSep(panel, 174)

-- ── egg count badge area ──────────────────────────────────────────
local countLbl = Instance.new("TextLabel", panel)
countLbl.Size = UDim2.new(1,-16,0,18); countLbl.Position = UDim2.new(0,8,0,177)
countLbl.BackgroundTransparency = 1
countLbl.TextColor3 = C.subtext
countLbl.TextScaled = true; countLbl.Font = Enum.Font.Gotham
countLbl.Text = ""; countLbl.TextXAlignment = Enum.TextXAlignment.Left

-- ── scroll list ───────────────────────────────────────────────────
local scroll = Instance.new("ScrollingFrame", panel)
scroll.Size = UDim2.new(1,-8,1,-200); scroll.Position = UDim2.new(0,4,0,198)
scroll.BackgroundTransparency = 1; scroll.BorderSizePixel = 0
scroll.ScrollBarThickness = 3
scroll.ScrollBarImageColor3 = C.accent
scroll.CanvasSize = UDim2.new(0,0,0,0)
scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y

local listLayout = Instance.new("UIListLayout", scroll)
listLayout.Padding = UDim.new(0,6)
local listPad = Instance.new("UIPadding", scroll)
listPad.PaddingLeft = UDim.new(0,4); listPad.PaddingRight = UDim.new(0,4)
listPad.PaddingTop  = UDim.new(0,4); listPad.PaddingBottom = UDim.new(0,4)

-- ─── card builder ─────────────────────────────────────────────────────────────
local function clearCards()
    for _, c in ipairs(scroll:GetChildren()) do
        if c:IsA("Frame") or c:IsA("TextLabel") then c:Destroy() end
    end
end

-- Mutation pill badge
local function makeMutBadge(parent, mut)
    local pill = Instance.new("Frame", parent)
    pill.Size = UDim2.new(0,0,0,18)
    pill.AutomaticSize = Enum.AutomaticSize.X
    pill.BackgroundColor3 = MUT_GLOW[mut] or MUT_GLOW.Normal
    pill.BorderSizePixel = 0
    pill.Position = UDim2.new(0,0,0,0)
    Instance.new("UICorner", pill).CornerRadius = UDim.new(1,0)
    local p = Instance.new("UIPadding", pill)
    p.PaddingLeft = UDim.new(0,6); p.PaddingRight = UDim.new(0,6)

    local lbl = Instance.new("TextLabel", pill)
    lbl.Size = UDim2.fromScale(1,1)
    lbl.BackgroundTransparency = 1
    lbl.TextColor3 = MUT_COLOR[mut] or Color3.new(1,1,1)
    lbl.TextScaled = true; lbl.Font = Enum.Font.GothamBold
    lbl.Text = mut
    return pill
end

local function buildCards(entries)
    clearCards()
    if #entries == 0 then
        local empty = Instance.new("TextLabel", scroll)
        empty.Size = UDim2.new(1,0,0,44)
        empty.BackgroundTransparency = 1
        empty.TextColor3 = C.subtext
        empty.TextScaled = true; empty.Font = Enum.Font.Gotham
        empty.Text = "ไม่เจอไข่ที่ unlock แล้ว\n(อาจกำลังถูก lock อยู่)"
        return
    end

    for i, entry in ipairs(entries) do
        local mutC = MUT_COLOR[entry.mutation] or C.text
        local glowC = MUT_GLOW[entry.mutation] or C.sep

        local card = Instance.new("Frame", scroll)
        card.Name = "Card_"..i
        card.LayoutOrder = i
        card.Size = UDim2.new(1,0,0,68)
        card.BackgroundColor3 = C.cardBg
        card.BorderSizePixel = 0
        Instance.new("UICorner", card).CornerRadius = UDim.new(0,10)
        do
            local s = Instance.new("UIStroke", card)
            s.Color = glowC; s.Thickness = 1.2
        end

        -- left accent bar
        local accent = Instance.new("Frame", card)
        accent.Size = UDim2.new(0,3,0.7,0); accent.Position = UDim2.new(0,0,0.15,0)
        accent.BackgroundColor3 = mutC; accent.BorderSizePixel = 0
        Instance.new("UICorner", accent).CornerRadius = UDim.new(1,0)

        -- index number
        local numLbl = Instance.new("TextLabel", card)
        numLbl.Size = UDim2.new(0,22,0,22); numLbl.Position = UDim2.new(0,6,0.5,-11)
        numLbl.BackgroundColor3 = C.accentDim; numLbl.BorderSizePixel = 0
        numLbl.TextColor3 = C.subtext
        numLbl.TextScaled = true; numLbl.Font = Enum.Font.GothamBold
        numLbl.Text = tostring(i)
        Instance.new("UICorner", numLbl).CornerRadius = UDim.new(0,5)

        -- info block
        local info = Instance.new("Frame", card)
        info.Size = UDim2.new(1,-110,1,-8); info.Position = UDim2.new(0,32,0,4)
        info.BackgroundTransparency = 1

        local tEgg = Instance.new("TextLabel", info)
        tEgg.Size = UDim2.new(1,0,0,22); tEgg.BackgroundTransparency = 1
        tEgg.TextColor3 = mutC
        tEgg.TextScaled = true; tEgg.Font = Enum.Font.GothamBold
        tEgg.Text = entry.eggName; tEgg.TextXAlignment = Enum.TextXAlignment.Left

        -- mutation badge + biome on line 2
        local line2 = Instance.new("Frame", info)
        line2.Size = UDim2.new(1,0,0,18); line2.Position = UDim2.new(0,0,0,24)
        line2.BackgroundTransparency = 1
        makeMutBadge(line2, entry.mutation)

        local biomeLbl = Instance.new("TextLabel", line2)
        biomeLbl.Size = UDim2.new(1,-80,1,0); biomeLbl.Position = UDim2.new(0,80,0,0)
        biomeLbl.BackgroundTransparency = 1
        biomeLbl.TextColor3 = C.subtext
        biomeLbl.TextScaled = true; biomeLbl.Font = Enum.Font.Gotham
        biomeLbl.Text = "📍 " .. entry.biome; biomeLbl.TextXAlignment = Enum.TextXAlignment.Left

        -- kg weight
        local kgLbl = Instance.new("TextLabel", info)
        kgLbl.Size = UDim2.new(1,0,0,16); kgLbl.Position = UDim2.new(0,0,0,44)
        kgLbl.BackgroundTransparency = 1
        kgLbl.TextColor3 = C.green
        kgLbl.TextScaled = true; kgLbl.Font = Enum.Font.Gotham
        kgLbl.Text = string.format("⚖️ %.2f kg  ·  %s", entry.kg, entry.nest)
        kgLbl.TextXAlignment = Enum.TextXAlignment.Left

        -- steal button
        local stealBtn = Instance.new("TextButton", card)
        stealBtn.Size = UDim2.new(0,58,0,30); stealBtn.Position = UDim2.new(1,-64,0.5,-15)
        stealBtn.BackgroundColor3 = C.stealBtn; stealBtn.BorderSizePixel = 0
        stealBtn.TextScaled = true; stealBtn.Font = Enum.Font.GothamBold
        stealBtn.TextColor3 = Color3.new(1,1,1)
        stealBtn.Text = "STEAL"
        Instance.new("UICorner", stealBtn).CornerRadius = UDim.new(0,8)
        do
            local g = Instance.new("UIGradient", stealBtn)
            g.Color = ColorSequence.new({
                ColorSequenceKeypoint.new(0, Color3.fromRGB(175,60,240)),
                ColorSequenceKeypoint.new(1, Color3.fromRGB(120,35,190)),
            })
            g.Rotation = 90
        end

        local entryRef = entry
        stealBtn.MouseButton1Click:Connect(function()
            if state.stealing then return end
            TweenService:Create(stealBtn, TweenInfo.new(0.1), {BackgroundColor3=C.stealHold}):Play()
            stealBtn.Text = "..."
            stealEgg(entryRef, function(msg) statusLbl.Text = msg end)
            task.wait(1.2)
            TweenService:Create(stealBtn, TweenInfo.new(0.1), {BackgroundColor3=C.stealBtn}):Play()
            stealBtn.Text = "STEAL"
        end)
    end
end

-- ─── scan action ──────────────────────────────────────────────────────────────
local function doScan()
    TweenService:Create(scanBtn, TweenInfo.new(0.12), {BackgroundColor3=C.accentDim}):Play()
    scanBtn.Text = "⏳ Scanning..."
    task.wait(0.05)

    local petInfo = getFastestOwnPet()
    if petInfo then
        rideLbl.Text = string.format("🐾 %s  (SH %.1f)", petInfo.name, petInfo.score/10)
    else
        rideLbl.Text = "⚠️ ไม่เจอสัตว์ใน base"
    end

    local entries = scanNests()
    buildCards(entries)

    local locked_count = 0
    do
        -- quick count of all eggs including locked ones for info
        local biomes = workspace:FindFirstChild("Map") and workspace.Map:FindFirstChild("Biomes")
        if biomes then
            local now = tick()
            for _, bf in ipairs(biomes:GetChildren()) do
                local nf = bf:FindFirstChild("Nests")
                if nf then
                    for _, n in ipairs(nf:GetChildren()) do
                        local e = n:FindFirstChild("Egg")
                        if e then
                            local l = e:GetAttribute("LockedUntil")
                            if l and l > now then locked_count += 1 end
                        end
                    end
                end
            end
        end
    end

    countLbl.Text = string.format(
        "เจอ %d ไข่  •  🔒 %d locked", #entries, locked_count)
    statusLbl.Text = string.format("พบ %d ไข่ ready — กด STEAL เพื่อขโมย", #entries)
    scanBtn.Text = string.format("🔍  Scan  (%d)", #entries)
    TweenService:Create(scanBtn, TweenInfo.new(0.12), {BackgroundColor3=C.accent}):Play()

    if state.esp then clearESP(); buildESP() end
end

scanBtn.MouseButton1Click:Connect(doScan)

-- ─── close / minimise ─────────────────────────────────────────────────────────
closeBtn.MouseButton1Click:Connect(function()
    TweenService:Create(panel, TweenInfo.new(0.18), {Size=UDim2.new(0,290,0,0)}):Play()
    task.wait(0.22); gui:Destroy(); unfreezeAll()
end)

local miniBtn = Instance.new("TextButton", gui)
miniBtn.Size = UDim2.new(0,38,0,38); miniBtn.Position = UDim2.new(0,8,0.5,-19)
miniBtn.BackgroundColor3 = C.titleBg; miniBtn.BorderSizePixel = 0
miniBtn.TextScaled = true; miniBtn.Font = Enum.Font.GothamBold
miniBtn.TextColor3 = C.text; miniBtn.Text = "🥚"; miniBtn.Visible = false
Instance.new("UICorner", miniBtn).CornerRadius = UDim.new(0,10)
do
    local s = Instance.new("UIStroke", miniBtn)
    s.Color = C.accent; s.Thickness = 1.2
end

miniBtn.MouseButton1Click:Connect(function()
    panel.Visible = true; miniBtn.Visible = false
end)
titleBar.InputBegan:Connect(function(inp)
    if inp.UserInputType == Enum.UserInputType.MouseButton2 then
        panel.Visible = false; miniBtn.Visible = true
    end
end)

-- ─── char respawn ──────────────────────────────────────────────────────────────
lp.CharacterAdded:Connect(function(c)
    char = c; hrp = c:WaitForChild("HumanoidRootPart")
    state.invincible = false; state.noclip = false; state.stealing = false
end)

-- ─── boot scan ─────────────────────────────────────────────────────────────────
task.delay(1.5, doScan)

-- ready v4 🥚
