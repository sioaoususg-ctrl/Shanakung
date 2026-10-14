-- [[ RSE NestInspector v6 ]]
-- Game:    Ride & Steal Eggs  (PlaceId 15448459363)
-- Engine:  Roblox / Luau  |  macOS executor (e.g. Script-Ware M)
-- Fix v6:
--   • per-pet income: การ์ดแสดง income ของแต่ละตัวในไข่ (kg × rarity weight)
--   • steal fix: TP → settle 0.35s → fire → retry loop 3× → wait 0.6s ก่อนกลับ

local Players    = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local RS = game:GetService("ReplicatedStorage")

local lp   = Players.LocalPlayer
local char = lp.Character or lp.CharacterAdded:Wait()
local hrp  = char:WaitForChild("HumanoidRootPart")

-- ─── state ───────────────────────────────────────────────────────────────────
local state = { invincible=false, noclip=false, esp=false, stealing=false }
local frozenGuardians = {}
local espBillboards   = {}

-- ─── mutation colours ────────────────────────────────────────────────────────
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
local MUT_MULT = { Normal=1, Gold=3, Diamond=6, Rainbow=12, Secret=30 }

-- rarity → relative income weight (ยิ่ง rare ยิ่งได้ต่อ kg มาก)
local RARITY_WEIGHT = {
    Common    = 1,
    Uncommon  = 1.5,
    Rare      = 2.5,
    Epic      = 5,
    Legendary = 12,
    Mythic    = 30,
    Secret    = 80,
}

-- ─── EggConfig loader ─────────────────────────────────────────────────────────
-- EGG_DATA[eggName] = { pets = { {name, chance, rarity}, ... } }
local EGG_DATA = {}

local function loadEggConfig()
    local ok, cfg = pcall(function()
        return require(RS:WaitForChild("Shared",2)
            :WaitForChild("Config",2)
            :WaitForChild("EggConfig",2))
    end)
    if not (ok and type(cfg) == "table") then return end
    for eggName, data in pairs(cfg) do
        if type(data) == "table" then
            local pets = data.pets or data.Pets or data.PetList or data.petList
            if type(pets) == "table" and #pets > 0 then
                local parsed = {}
                for _, p in ipairs(pets) do
                    if type(p) == "table" then
                        parsed[#parsed+1] = {
                            name    = p.name or p.Name or p.petName or "?",
                            chance  = tonumber(p.chance or p.Chance or p.rate or 0) or 0,
                            rarity  = p.rarity or p.Rarity or "Common",
                        }
                    else
                        parsed[#parsed+1] = { name=tostring(p), chance=0, rarity="Common" }
                    end
                end
                EGG_DATA[eggName] = { pets = parsed }
            end
        end
    end
end
pcall(loadEggConfig)

-- ─── per-pet income line ──────────────────────────────────────────────────────
-- คืน table ของ { label=string, income=number } เรียงจากมากไปน้อย
local function calcPerPetIncome(eggName, kg, mutation)
    local mutMult = MUT_MULT[mutation] or 1
    local base    = kg * mutMult
    local data    = EGG_DATA[eggName]
    if not data then
        -- fallback: ไม่มี config → ใช้ egg label อย่างเดียว
        return { { label = (eggName:gsub("Egg$","")) .. " Pet", income = base } }
    end
    local out = {}
    for _, pet in ipairs(data.pets) do
        local rw     = RARITY_WEIGHT[pet.rarity] or 1
        local income = base * rw
        out[#out+1]  = {
            label  = pet.name,
            rarity = pet.rarity or "Common",
            chance = pet.chance,
            income = income,
        }
    end
    -- sort by income desc
    table.sort(out, function(a,b) return a.income > b.income end)
    return out
end

-- ─── display helpers ─────────────────────────────────────────────────────────
local function fmtCoins(v)
    if v >= 1e6 then return string.format("%.1fM", v/1e6) end
    if v >= 1e3 then return string.format("%.1fK", v/1e3) end
    return string.format("%.2f", v)
end

local function getPetLabel(eggName)
    local data = EGG_DATA[eggName]
    if data and #data.pets > 0 then
        local names = {}
        for i, p in ipairs(data.pets) do
            if i > 3 then names[#names+1] = "..."; break end
            names[#names+1] = p.name
        end
        return table.concat(names, ", ")
    end
    return (eggName:gsub("Egg$","")) .. " Pet"
end

local function estimateCoins(kg, mutation)
    return kg * (MUT_MULT[mutation] or 1)
end

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

-- ─── egg scan ────────────────────────────────────────────────────────────────
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
                    local locked = egg:GetAttribute("LockedUntil")
                    local available = (not locked) or (locked <= now)
                    if available then
                        local eggName = egg:GetAttribute("EggName") or nest.Name
                        local kg      = tonumber(egg:GetAttribute("Kg")) or 0
                        local mut     = egg:GetAttribute("Mutation") or "Normal"
                        local aura    = egg:GetAttribute("Aura")
                        local displayMut = aura or mut
                        local coins = estimateCoins(kg, displayMut)
                        local perPet = calcPerPetIncome(eggName, kg, displayMut)
                        table.insert(results, {
                            biome    = biomeF.Name,
                            nest     = nest.Name,
                            egg      = egg,
                            eggName  = eggName,
                            petLabel = getPetLabel(eggName),
                            kg       = kg,
                            mutation = displayMut,
                            coins    = coins,
                            perPet   = perPet,  -- { label, income, rarity, chance }
                        })
                    end
                end
            end
        end
    end
    table.sort(results, function(a, b) return a.coins > b.coins end)
    return results
end

local function bestPerZone(entries)
    local zones = {}
    for _, e in ipairs(entries) do
        if not zones[e.biome] or e.coins > zones[e.biome].coins then
            zones[e.biome] = e
        end
    end
    local out = {}
    for _, v in pairs(zones) do out[#out+1] = v end
    table.sort(out, function(a,b) return a.coins > b.coins end)
    return out
end

-- ─── steal (v6: retry loop + proper wait before return) ──────────────────────
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
    else
        task.wait(0.2)
    end

    upd("🧊 Freeze " .. entry.biome .. "...")
    freezeGuardian(entry.biome)
    task.wait(0.1)

    local eggPart = entry.egg
    if not eggPart or not eggPart.Parent then
        upd("❌ Egg หายแล้ว — abort")
        state.stealing = false; return
    end

    -- หา prompt ก่อน TP (ยังอยู่ใน parent เดิม)
    local prompt = eggPart:FindFirstChildWhichIsA("ProximityPrompt", true)

    upd("🚀 TP → " .. entry.petLabel .. "...")
    hrp.CFrame = eggPart.CFrame + Vector3.new(0, 2.5, 0)

    -- settle: ให้ engine จัดตำแหน่งก่อน
    task.wait(0.35)

    -- re-check egg ยังอยู่ไหม
    if not eggPart or not eggPart.Parent then
        upd("❌ Egg หายระหว่าง TP — abort")
        state.stealing = false; return
    end

    -- re-find prompt หลัง TP เผื่อมัน stream เข้ามาหลัง TP
    if not prompt then
        prompt = eggPart:FindFirstChildWhichIsA("ProximityPrompt", true)
    end

    if prompt then
        -- zero HoldDuration → instant fire
        pcall(function() prompt.HoldDuration = 0 end)

        -- retry loop 3 ครั้ง ห่างกัน 0.25s
        local fired = false
        for attempt = 1, 3 do
            upd(string.format("🔓 Fire prompt (%d/3)...", attempt))
            local ok = pcall(fireproximityprompt, prompt)
            if ok then fired = true end
            task.wait(0.25)
            -- ถ้า egg หายไปแล้ว (ถูกขโมยสำเร็จ) หยุดได้เลย
            if not eggPart or not eggPart.Parent then
                upd("✅ Egg หายแล้ว — สำเร็จ!")
                break
            end
        end
        if not fired then
            upd("⚠️ fireproximityprompt ล้มเหลวทุกครั้ง")
        end
    else
        upd("⚠️ ไม่เจอ prompt — ลอง fire บน parent")
        -- fallback: ลอง fire บน nest parent
        local nestPrompt = eggPart.Parent and
            eggPart.Parent:FindFirstChildWhichIsA("ProximityPrompt", true)
        if nestPrompt then
            pcall(function() nestPrompt.HoldDuration = 0 end)
            pcall(fireproximityprompt, nestPrompt)
        end
        task.wait(0.5)
    end

    -- รอให้ animation/replication จบก่อนกลับ
    task.wait(0.6)

    upd("🏠 กลับ base...")
    hrp.CFrame = getBaseSpawnCF()
    task.wait(0.1)

    upd(string.format("✅ Done — %s [%s] ~%s 🪙", entry.petLabel, entry.mutation, fmtCoins(entry.coins)))
    state.stealing = false
end

-- ─── ESP ─────────────────────────────────────────────────────────────────────
local function buildESP()
    local nests = scanNests()
    for _, entry in ipairs(nests) do
        local egg = entry.egg
        if egg and egg.Parent and not espBillboards[egg] then
            local bb = Instance.new("BillboardGui")
            bb.Name = "RSE_ESP_v6"
            bb.AlwaysOnTop = true
            bb.Size = UDim2.new(0, 160, 0, 54)
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
            tName.Size = UDim2.new(1,-6,0.45,0); tName.Position = UDim2.new(0,3,0,2)
            tName.BackgroundTransparency = 1
            tName.TextColor3 = MUT_COLOR[entry.mutation] or Color3.new(1,1,1)
            tName.TextScaled = true; tName.Font = Enum.Font.GothamBold
            tName.Text = entry.petLabel

            local tSub = Instance.new("TextLabel", bg)
            tSub.Size = UDim2.new(1,-6,0.32,0); tSub.Position = UDim2.new(0,3,0.48,0)
            tSub.BackgroundTransparency = 1
            tSub.TextColor3 = Color3.fromRGB(160,240,140)
            tSub.TextScaled = true; tSub.Font = Enum.Font.Gotham
            tSub.Text = string.format("⚖️ %.2f kg  •  🪙 %s", entry.kg, fmtCoins(entry.coins))

            local tBiome = Instance.new("TextLabel", bg)
            tBiome.Size = UDim2.new(1,-6,0.25,0); tBiome.Position = UDim2.new(0,3,0.76,0)
            tBiome.BackgroundTransparency = 1
            tBiome.TextColor3 = Color3.fromRGB(130,115,170)
            tBiome.TextScaled = true; tBiome.Font = Enum.Font.Gotham
            tBiome.Text = "📍 " .. entry.biome

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
--  UI  v6
-- ═══════════════════════════════════════════════════════════════
local gui = Instance.new("ScreenGui")
gui.Name = "RSENestInspector_v6"
gui.ResetOnSpawn = false
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent = (pcall(function() return gethui() end) and gethui()) or lp.PlayerGui

local C = {
    bg       = Color3.fromRGB(10, 8, 20),
    panel    = Color3.fromRGB(15, 12, 28),
    titleBg  = Color3.fromRGB(22, 16, 44),
    accent   = Color3.fromRGB(130, 80, 230),
    accentDim= Color3.fromRGB(70,  42, 130),
    text     = Color3.fromRGB(215, 200, 255),
    subtext  = Color3.fromRGB(130, 115, 170),
    green    = Color3.fromRGB(120, 240, 140),
    gold     = Color3.fromRGB(255, 210, 60),
    stripBg  = Color3.fromRGB(20,  16,  38),
    cardBg   = Color3.fromRGB(18,  14,  34),
    zoneBg   = Color3.fromRGB(14,  10,  28),
    sep      = Color3.fromRGB(48,  38,  80),
    stealBtn = Color3.fromRGB(150, 45,  215),
    stealHold= Color3.fromRGB(80,  22,  120),
    closeBg  = Color3.fromRGB(180, 40,  50),
    incomeRow= Color3.fromRGB(22,  18,  40),
}

-- panel 310 × 540 (สูงขึ้นนิดนึงเพราะการ์ดสูงขึ้น)
local panel = Instance.new("Frame", gui)
panel.Name = "MainPanel"
panel.Size = UDim2.new(0, 310, 0, 540)
panel.Position = UDim2.new(0.5, -155, 0.5, -270)
panel.BackgroundColor3 = C.panel
panel.BorderSizePixel = 0
panel.Active = true
panel.Draggable = true
Instance.new("UICorner", panel).CornerRadius = UDim.new(0, 12)
do local s = Instance.new("UIStroke", panel); s.Color = C.accent; s.Thickness = 1.5 end

-- title bar
local titleBar = Instance.new("Frame", panel)
titleBar.Size = UDim2.new(1, 0, 0, 36)
titleBar.BackgroundColor3 = C.titleBg
titleBar.BorderSizePixel = 0
do
    Instance.new("UICorner", titleBar).CornerRadius = UDim.new(0,12)
    local fix = Instance.new("Frame", titleBar)
    fix.Size = UDim2.new(1,0,0.5,0); fix.Position = UDim2.new(0,0,0.5,0)
    fix.BackgroundColor3 = C.titleBg; fix.BorderSizePixel = 0
end
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
titleLbl.Text = "🥚  RSE NestInspector  v6"
titleLbl.TextXAlignment = Enum.TextXAlignment.Left

local closeBtn = Instance.new("TextButton", titleBar)
closeBtn.Size = UDim2.new(0,24,0,24); closeBtn.Position = UDim2.new(1,-28,0.5,-12)
closeBtn.BackgroundColor3 = C.closeBg; closeBtn.BorderSizePixel = 0
closeBtn.Text = "✕"; closeBtn.TextScaled = true; closeBtn.Font = Enum.Font.GothamBold
closeBtn.TextColor3 = Color3.new(1,1,1)
Instance.new("UICorner", closeBtn).CornerRadius = UDim.new(0,6)

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

local rideStrip = Instance.new("Frame", panel)
rideStrip.Size = UDim2.new(1,-16,0,22); rideStrip.Position = UDim2.new(0,8,0,56)
rideStrip.BackgroundColor3 = C.stripBg; rideStrip.BorderSizePixel = 0
Instance.new("UICorner", rideStrip).CornerRadius = UDim.new(0,6)
local rideLbl = Instance.new("TextLabel", rideStrip)
rideLbl.Size = UDim2.fromScale(1,1); rideLbl.BackgroundTransparency = 1
rideLbl.TextColor3 = C.green; rideLbl.TextScaled = true; rideLbl.Font = Enum.Font.Gotham
rideLbl.Text = "🐾 สัตว์เร็วสุด: กด Scan"

local toggleRow = Instance.new("Frame", panel)
toggleRow.Size = UDim2.new(1,-16,0,28); toggleRow.Position = UDim2.new(0,8,0,81)
toggleRow.BackgroundTransparency = 1
do local l = Instance.new("UIListLayout", toggleRow)
   l.FillDirection = Enum.FillDirection.Horizontal; l.Padding = UDim.new(0,6) end

local function makeToggle(parent, lbl, key, cb)
    local btn = Instance.new("TextButton", parent)
    btn.Size = UDim2.new(0,80,1,0)
    btn.BackgroundColor3 = C.accentDim; btn.BorderSizePixel = 0
    btn.TextScaled = true; btn.Font = Enum.Font.GothamSemibold
    btn.TextColor3 = C.subtext; btn.Text = lbl .. " OFF"
    Instance.new("UICorner", btn).CornerRadius = UDim.new(0,7)
    do local s = Instance.new("UIStroke", btn); s.Color = C.sep; s.Thickness = 1 end
    btn.MouseButton1Click:Connect(function()
        state[key] = not state[key]
        if state[key] then
            btn.BackgroundColor3 = C.accent; btn.TextColor3 = Color3.new(1,1,1)
            btn.Text = lbl .. " ON"
        else
            btn.BackgroundColor3 = C.accentDim; btn.TextColor3 = C.subtext
            btn.Text = lbl .. " OFF"
        end
        if cb then cb(state[key]) end
    end)
    return btn
end

makeToggle(toggleRow,"Invinc","invincible",function(on) if on then startInvincible() end end)
makeToggle(toggleRow,"NoClip","noclip",    function(on) if on then startNoclip() end end)
makeToggle(toggleRow,"ESP","esp",          function(on) if on then buildESP() else clearESP() end end)

local function makeSep(parent, yPos)
    local s = Instance.new("Frame", parent)
    s.Size = UDim2.new(1,-16,0,1); s.Position = UDim2.new(0,8,0,yPos)
    s.BackgroundColor3 = C.sep; s.BorderSizePixel = 0
    return s
end
makeSep(panel, 112)

local statusBar = Instance.new("Frame", panel)
statusBar.Size = UDim2.new(1,-16,0,24); statusBar.Position = UDim2.new(0,8,0,115)
statusBar.BackgroundColor3 = C.stripBg; statusBar.BorderSizePixel = 0
Instance.new("UICorner", statusBar).CornerRadius = UDim.new(0,6)
local statusLbl = Instance.new("TextLabel", statusBar)
statusLbl.Size = UDim2.new(1,-8,1,0); statusLbl.Position = UDim2.new(0,4,0,0)
statusLbl.BackgroundTransparency = 1
statusLbl.TextColor3 = C.text; statusLbl.TextScaled = true; statusLbl.Font = Enum.Font.Gotham
statusLbl.Text = "พร้อมใช้งาน — กด Scan"; statusLbl.TextXAlignment = Enum.TextXAlignment.Left

local scanBtn = Instance.new("TextButton", panel)
scanBtn.Size = UDim2.new(1,-16,0,28); scanBtn.Position = UDim2.new(0,8,0,142)
scanBtn.BackgroundColor3 = C.accent; scanBtn.BorderSizePixel = 0
scanBtn.TextScaled = true; scanBtn.Font = Enum.Font.GothamBold
scanBtn.TextColor3 = Color3.new(1,1,1); scanBtn.Text = "🔍  Scan Nests"
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

local countLbl = Instance.new("TextLabel", panel)
countLbl.Size = UDim2.new(1,-16,0,16); countLbl.Position = UDim2.new(0,8,0,177)
countLbl.BackgroundTransparency = 1; countLbl.TextColor3 = C.subtext
countLbl.TextScaled = true; countLbl.Font = Enum.Font.Gotham
countLbl.Text = ""; countLbl.TextXAlignment = Enum.TextXAlignment.Left

local tabRow = Instance.new("Frame", panel)
tabRow.Size = UDim2.new(1,-16,0,24); tabRow.Position = UDim2.new(0,8,0,196)
tabRow.BackgroundTransparency = 1
do local l = Instance.new("UIListLayout", tabRow)
   l.FillDirection = Enum.FillDirection.Horizontal; l.Padding = UDim.new(0,4) end

local function makeTab(parent, txt)
    local btn = Instance.new("TextButton", parent)
    btn.Size = UDim2.new(0.5,-2,1,0)
    btn.BackgroundColor3 = C.accentDim; btn.BorderSizePixel = 0
    btn.TextScaled = true; btn.Font = Enum.Font.GothamSemibold
    btn.TextColor3 = C.subtext; btn.Text = txt
    Instance.new("UICorner", btn).CornerRadius = UDim.new(0,6)
    return btn
end
local tabBest = makeTab(tabRow, "🏆 Best/Zone")
local tabAll  = makeTab(tabRow, "📋 All Eggs")
local activeTab = "best"

local scroll = Instance.new("ScrollingFrame", panel)
scroll.Size = UDim2.new(1,-8,1,-226); scroll.Position = UDim2.new(0,4,0,224)
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

local function clearCards()
    for _, c in ipairs(scroll:GetChildren()) do
        if c:IsA("Frame") or c:IsA("TextLabel") then c:Destroy() end
    end
end

local function makeMutBadge(parent, mut)
    local pill = Instance.new("Frame", parent)
    pill.Size = UDim2.new(0,0,0,18)
    pill.AutomaticSize = Enum.AutomaticSize.X
    pill.BackgroundColor3 = MUT_GLOW[mut] or MUT_GLOW.Normal
    pill.BorderSizePixel = 0
    Instance.new("UICorner", pill).CornerRadius = UDim.new(1,0)
    local p = Instance.new("UIPadding", pill)
    p.PaddingLeft = UDim.new(0,6); p.PaddingRight = UDim.new(0,6)
    local lbl = Instance.new("TextLabel", pill)
    lbl.Size = UDim2.fromScale(1,1); lbl.BackgroundTransparency = 1
    lbl.TextColor3 = MUT_COLOR[mut] or Color3.new(1,1,1)
    lbl.TextScaled = true; lbl.Font = Enum.Font.GothamBold
    lbl.Text = mut
    return pill
end

-- ─── card builder v6 ─────────────────────────────────────────────────────────
local function buildCard(i, entry, isZoneBest)
    local mutC  = MUT_COLOR[entry.mutation] or C.text
    local glowC = MUT_GLOW[entry.mutation] or C.sep

    -- คำนวณสูงการ์ด: base 96 + 14px ต่อ pet (สูงสุด 3 ตัว)
    local maxPets   = math.min(#entry.perPet, 3)
    local cardH     = 96 + maxPets * 14

    local card = Instance.new("Frame", scroll)
    card.Name = "Card_"..i
    card.LayoutOrder = i
    card.Size = UDim2.new(1, 0, 0, cardH)
    card.BackgroundColor3 = isZoneBest and C.zoneBg or C.cardBg
    card.BorderSizePixel = 0
    Instance.new("UICorner", card).CornerRadius = UDim.new(0,10)
    do local s = Instance.new("UIStroke", card); s.Color = glowC; s.Thickness = 1.2 end

    local accent = Instance.new("Frame", card)
    accent.Size = UDim2.new(0,3,0.7,0); accent.Position = UDim2.new(0,0,0.15,0)
    accent.BackgroundColor3 = mutC; accent.BorderSizePixel = 0
    Instance.new("UICorner", accent).CornerRadius = UDim.new(1,0)

    local numLbl = Instance.new("TextLabel", card)
    numLbl.Size = UDim2.new(0,22,0,22); numLbl.Position = UDim2.new(0,6,0,6)
    numLbl.BackgroundColor3 = C.accentDim; numLbl.BorderSizePixel = 0
    numLbl.TextColor3 = C.subtext; numLbl.TextScaled = true; numLbl.Font = Enum.Font.GothamBold
    numLbl.Text = tostring(i)
    Instance.new("UICorner", numLbl).CornerRadius = UDim.new(0,5)

    -- info block
    local info = Instance.new("Frame", card)
    info.Size = UDim2.new(1,-110,0,cardH-8); info.Position = UDim2.new(0,32,0,4)
    info.BackgroundTransparency = 1

    -- line 1: pet label
    local tPet = Instance.new("TextLabel", info)
    tPet.Size = UDim2.new(1,0,0,18); tPet.BackgroundTransparency = 1
    tPet.TextColor3 = mutC; tPet.TextScaled = true; tPet.Font = Enum.Font.GothamBold
    tPet.Text = entry.petLabel; tPet.TextXAlignment = Enum.TextXAlignment.Left

    -- line 2: egg name
    local tEgg = Instance.new("TextLabel", info)
    tEgg.Size = UDim2.new(1,0,0,13); tEgg.Position = UDim2.new(0,0,0,19)
    tEgg.BackgroundTransparency = 1
    tEgg.TextColor3 = C.subtext; tEgg.TextScaled = true; tEgg.Font = Enum.Font.Gotham
    tEgg.Text = "🥚 " .. entry.eggName; tEgg.TextXAlignment = Enum.TextXAlignment.Left

    -- line 3: mutation badge + biome
    local line3 = Instance.new("Frame", info)
    line3.Size = UDim2.new(1,0,0,18); line3.Position = UDim2.new(0,0,0,33)
    line3.BackgroundTransparency = 1
    makeMutBadge(line3, entry.mutation)
    local biomeLbl = Instance.new("TextLabel", line3)
    biomeLbl.Size = UDim2.new(1,-80,1,0); biomeLbl.Position = UDim2.new(0,80,0,0)
    biomeLbl.BackgroundTransparency = 1; biomeLbl.TextColor3 = C.subtext
    biomeLbl.TextScaled = true; biomeLbl.Font = Enum.Font.Gotham
    biomeLbl.Text = "📍 " .. entry.biome; biomeLbl.TextXAlignment = Enum.TextXAlignment.Left

    -- line 4: total kg + coins
    local kgLbl = Instance.new("TextLabel", info)
    kgLbl.Size = UDim2.new(1,0,0,13); kgLbl.Position = UDim2.new(0,0,0,52)
    kgLbl.BackgroundTransparency = 1; kgLbl.TextColor3 = C.gold
    kgLbl.TextScaled = true; kgLbl.Font = Enum.Font.Gotham
    kgLbl.Text = string.format("⚖️ %.2f kg  ·  🪙 ~%s", entry.kg, fmtCoins(entry.coins))
    kgLbl.TextXAlignment = Enum.TextXAlignment.Left

    -- ─── per-pet income rows (สูงสุด 3 ตัว) ────────────────────────────────
    local yOff = 67
    for pi = 1, maxPets do
        local pet   = entry.perPet[pi]
        local pRow  = Instance.new("Frame", info)
        pRow.Size   = UDim2.new(1,0,0,12)
        pRow.Position = UDim2.new(0,0,0,yOff + (pi-1)*14)
        pRow.BackgroundColor3 = C.incomeRow
        pRow.BorderSizePixel  = 0
        Instance.new("UICorner", pRow).CornerRadius = UDim.new(0,4)

        local pLbl = Instance.new("TextLabel", pRow)
        pLbl.Size = UDim2.fromScale(1,1); pLbl.BackgroundTransparency = 1
        pLbl.TextColor3 = Color3.fromRGB(190,255,190)
        pLbl.TextScaled = true; pLbl.Font = Enum.Font.Gotham
        pLbl.TextXAlignment = Enum.TextXAlignment.Left
        pLbl.Text = string.format(
            "  🐾 %s  ·  🪙 ~%s  [%s]",
            pet.label,
            fmtCoins(pet.income),
            pet.rarity or "?"
        )
    end
    if #entry.perPet > 3 then
        local moreRow = Instance.new("Frame", info)
        moreRow.Size = UDim2.new(1,0,0,12)
        moreRow.Position = UDim2.new(0,0,0, yOff + 3*14)
        moreRow.BackgroundTransparency = 1; moreRow.BorderSizePixel = 0
        local mLbl = Instance.new("TextLabel", moreRow)
        mLbl.Size = UDim2.fromScale(1,1); mLbl.BackgroundTransparency = 1
        mLbl.TextColor3 = C.subtext; mLbl.TextScaled = true; mLbl.Font = Enum.Font.Gotham
        mLbl.TextXAlignment = Enum.TextXAlignment.Left
        mLbl.Text = string.format("  + %d ตัวอื่น...", #entry.perPet - 3)
    end

    -- steal button
    local stealBtn = Instance.new("TextButton", card)
    stealBtn.Size = UDim2.new(0,60,0,30); stealBtn.Position = UDim2.new(1,-66,0,8)
    stealBtn.BackgroundColor3 = C.stealBtn; stealBtn.BorderSizePixel = 0
    stealBtn.TextScaled = true; stealBtn.Font = Enum.Font.GothamBold
    stealBtn.TextColor3 = Color3.new(1,1,1); stealBtn.Text = "STEAL"
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
        task.spawn(function()
            stealEgg(entryRef, function(msg) statusLbl.Text = msg end)
            task.wait(1)
            TweenService:Create(stealBtn, TweenInfo.new(0.1), {BackgroundColor3=C.stealBtn}):Play()
            stealBtn.Text = "STEAL"
        end)
    end)
end

local lastEntries = {}

local function buildCards(entries, tab)
    clearCards()
    local list = entries
    if tab == "best" then list = bestPerZone(entries) end
    if #list == 0 then
        local empty = Instance.new("TextLabel", scroll)
        empty.Size = UDim2.new(1,0,0,44); empty.BackgroundTransparency = 1
        empty.TextColor3 = C.subtext; empty.TextScaled = true; empty.Font = Enum.Font.Gotham
        empty.Text = "ไม่เจอไข่ที่ unlock แล้ว"
        return
    end
    for i, entry in ipairs(list) do
        buildCard(i, entry, tab == "best")
    end
end

local function setTab(t)
    activeTab = t
    if t == "best" then
        tabBest.BackgroundColor3 = C.accent; tabBest.TextColor3 = Color3.new(1,1,1)
        tabAll.BackgroundColor3  = C.accentDim; tabAll.TextColor3  = C.subtext
    else
        tabAll.BackgroundColor3  = C.accent; tabAll.TextColor3  = Color3.new(1,1,1)
        tabBest.BackgroundColor3 = C.accentDim; tabBest.TextColor3 = C.subtext
    end
    buildCards(lastEntries, activeTab)
end
setTab("best")

tabBest.MouseButton1Click:Connect(function() setTab("best") end)
tabAll.MouseButton1Click:Connect(function()  setTab("all")  end)

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

    lastEntries = scanNests()
    buildCards(lastEntries, activeTab)

    local locked_count = 0
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

    countLbl.Text = string.format("เจอ %d ไข่  •  🔒 %d locked", #lastEntries, locked_count)
    statusLbl.Text = string.format("พบ %d ไข่ ready — กด STEAL เพื่อขโมย", #lastEntries)
    scanBtn.Text = string.format("🔍  Scan  (%d)", #lastEntries)
    TweenService:Create(scanBtn, TweenInfo.new(0.12), {BackgroundColor3=C.accent}):Play()

    if state.esp then clearESP(); buildESP() end
end

scanBtn.MouseButton1Click:Connect(doScan)

closeBtn.MouseButton1Click:Connect(function()
    TweenService:Create(panel, TweenInfo.new(0.18), {Size=UDim2.new(0,310,0,0)}):Play()
    task.wait(0.22); gui:Destroy(); unfreezeAll()
end)

local miniBtn = Instance.new("TextButton", gui)
miniBtn.Size = UDim2.new(0,38,0,38); miniBtn.Position = UDim2.new(0,8,0.5,-19)
miniBtn.BackgroundColor3 = C.titleBg; miniBtn.BorderSizePixel = 0
miniBtn.TextScaled = true; miniBtn.Font = Enum.Font.GothamBold
miniBtn.TextColor3 = C.text; miniBtn.Text = "🥚"; miniBtn.Visible = false
Instance.new("UICorner", miniBtn).CornerRadius = UDim.new(0,10)
do local s = Instance.new("UIStroke", miniBtn); s.Color = C.accent; s.Thickness = 1.2 end

miniBtn.MouseButton1Click:Connect(function() panel.Visible = true; miniBtn.Visible = false end)
titleBar.InputBegan:Connect(function(inp)
    if inp.UserInputType == Enum.UserInputType.MouseButton2 then
        panel.Visible = false; miniBtn.Visible = true
    end
end)

lp.CharacterAdded:Connect(function(c)
    char = c; hrp = c:WaitForChild("HumanoidRootPart")
    state.invincible = false; state.noclip = false; state.stealing = false
end)

task.delay(1.5, doScan)

-- ready v6 🥚
