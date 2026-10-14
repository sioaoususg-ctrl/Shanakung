-- [[ RSE NestInspector v3 ]]
-- [context: Roblox executor, Windows x64, PlaceId 15448459363 "Ride & Steal Eggs"]
-- Flow: Auto-ride fastest pet in own base → TP to egg → fireproximityprompt → TP to own base
-- Ride via fireproximityprompt(pet.HumanoidRootPart.RidePrompt)
-- Guardian bypass: anchor all BaseParts of [Biome]Guardian client-side

local Players   = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local lp  = Players.LocalPlayer
local char = lp.Character or lp.CharacterAdded:Wait()
local hrp  = char:WaitForChild("HumanoidRootPart")

-- ─── state ───────────────────────────────────────────────────────────────────
local state = {
    invincible = false,
    noclip     = false,
    esp        = false,
    stealing   = false,
}

local frozenGuardians = {}
local espBillboards   = {}

-- ─── helpers ─────────────────────────────────────────────────────────────────
local function parseKey(k)
    if not k or k == "" then return nil end
    local p = string.split(k, "|")
    return {
        name    = p[1] or "?",
        variant = p[2] or "Normal",
        income  = tonumber(p[4]) or 0,
        level   = tonumber(p[5]) or 1,
    }
end

local function getPlayerBase()
    local bases = workspace:FindFirstChild("Map")
        and workspace.Map:FindFirstChild("Bases")
    if not bases then return nil end
    for _, b in ipairs(bases:GetChildren()) do
        if b:GetAttribute("OwnerId") == lp.UserId then
            return b
        end
    end
end

local function getBaseSpawnCF()
    local base = getPlayerBase()
    if base then
        local pen = base:FindFirstChild("PenPets") or base
        -- use base's primary part if it has one, else first child position
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
-- Pick the fastest rideable pet the player owns.
-- Proxy for speed: SeatHeight attr (bigger pet = faster game speed).
-- Fallback: income/hr from Key attr.
local function getFastestOwnPet()
    local base = getPlayerBase()
    if not base then return nil end
    local pen = base:FindFirstChild("PenPets")
    if not pen then return nil end

    local best, bestScore = nil, -1
    for _, pet in ipairs(pen:GetChildren()) do
        if pet:GetAttribute("OwnerId") == lp.UserId then
            local hrpPet = pet:FindFirstChild("HumanoidRootPart")
            if hrpPet then
                local ridePrompt = hrpPet:FindFirstChild("RidePrompt")
                if ridePrompt then
                    -- Score: SeatHeight * 10 + income
                    local seatH  = tonumber(pet:GetAttribute("SeatHeight")) or 0
                    local key    = pet:GetAttribute("Key") or ""
                    local parsed = parseKey(key)
                    local income = parsed and parsed.income or 0
                    local score  = seatH * 10 + income
                    if score > bestScore then
                        bestScore = score
                        best = { model = pet, hrp = hrpPet, prompt = ridePrompt,
                                 name = pet:GetAttribute("PetName") or pet.Name,
                                 score = score }
                    end
                end
            end
        end
    end
    return best
end

-- Mount the pet: TP next to it → fireproximityprompt → wait for Mode = Ride
local function mountPet(petInfo)
    if not petInfo then return false end
    -- TP to pet
    hrp.CFrame = petInfo.hrp.CFrame + Vector3.new(0, 3, 2)
    task.wait(0.15)
    -- Fire ride prompt
    pcall(fireproximityprompt, petInfo.prompt)
    task.wait(0.3)
    -- Verify via ShownPet Mode attribute on character
    local riding = false
    for _, obj in ipairs(char:GetDescendants()) do
        if obj.Name == "ShownPet" and obj:GetAttribute("Mode") == "Ride" then
            riding = true; break
        end
    end
    return riding
end

-- Check if currently riding
local function isRiding()
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
            table.insert(frozenGuardians[guardian], { part = part, was = was })
        end
    end
end

local function unfreezeAll()
    for _, list in pairs(frozenGuardians) do
        for _, e in ipairs(list) do
            pcall(function() e.part.Anchored = e.was end)
        end
    end
    frozenGuardians = {}
end

-- ─── egg scan ────────────────────────────────────────────────────────────────
local function scanNests()
    local results = {}
    local biomes = workspace:FindFirstChild("Map")
        and workspace.Map:FindFirstChild("Biomes")
    if not biomes then return results end

    for _, biomeF in ipairs(biomes:GetChildren()) do
        local nestsF = biomeF:FindFirstChild("Nests")
        if nestsF then
            for _, nest in ipairs(nestsF:GetChildren()) do
                local egg = nest:FindFirstChild("Egg")
                if egg then
                    local locked = egg:GetAttribute("LockedUntil")
                    if not locked or locked == 0 or locked <= os.time() then
                        local rawKey = egg:GetAttribute("Key")
                            or egg:GetAttribute("PetKey") or ""
                        local parsed = parseKey(rawKey)
                        if parsed then
                            table.insert(results, {
                                biome   = biomeF.Name,
                                nest    = nest.Name,
                                egg     = egg,
                                petName = parsed.name,
                                variant = parsed.variant,
                                income  = parsed.income,
                                eggName = egg:GetAttribute("EggName") or nest.Name,
                            })
                        end
                    end
                end
            end
        end
    end

    table.sort(results, function(a, b) return a.income > b.income end)
    return results
end

-- ─── full steal flow ─────────────────────────────────────────────────────────
-- 1. Mount fastest pet   2. Freeze guardian
-- 3. TP to egg           4. Fire egg prompt
-- 5. TP to own base
local currentRidingPet = nil

local function stealEgg(entry, statusCb)
    if state.stealing then return end
    state.stealing = true
    local function upd(msg) if statusCb then statusCb(msg) end end

    -- 1. Mount fastest pet
    upd("🐾 หาสัตว์เร็วสุด...")
    local petInfo = getFastestOwnPet()
    if petInfo then
        upd("🐾 ขึ้น " .. petInfo.name .. "...")
        local ok = mountPet(petInfo)
        currentRidingPet = petInfo
        if not ok then
            -- mount might still be in progress server-side, give extra time
            task.wait(0.5)
        end
        upd("🐾 ขึ้นสำเร็จ!")
    else
        upd("⚠️ ไม่เจอสัตว์ใน base")
        task.wait(0.4)
    end

    -- 2. Freeze guardian
    upd("🧊 Freeze " .. entry.biome .. " Guardian...")
    freezeGuardian(entry.biome)
    task.wait(0.15)

    -- 3. TP to egg
    local eggPart = entry.egg
    if not eggPart or not eggPart.Parent then
        upd("❌ Egg หายแล้ว")
        state.stealing = false
        return
    end
    upd("🚀 TP ไปหาไข่...")
    hrp.CFrame = eggPart.CFrame + Vector3.new(0, 3, 0)
    task.wait(0.2)

    -- 4. Fire egg proximity prompt
    upd("🥚 Steal...")
    local prompt = eggPart:FindFirstChildWhichIsA("ProximityPrompt", true)
    if prompt then
        pcall(fireproximityprompt, prompt)
        task.wait(0.35)
    end

    -- 5. TP to own base
    upd("🏠 กลับ base...")
    hrp.CFrame = getBaseSpawnCF()
    task.wait(0.1)

    upd("✅ Done!")
    state.stealing = false
end

-- ─── ESP ─────────────────────────────────────────────────────────────────────
local VARIANT_COLOR = {
    Normal  = Color3.fromRGB(220, 220, 220),
    Gold    = Color3.fromRGB(255, 215, 0),
    Diamond = Color3.fromRGB(100, 220, 255),
    Rainbow = Color3.fromRGB(255, 100, 255),
    Secret  = Color3.fromRGB(255, 80,  80),
}

local function buildESP()
    local nests = scanNests()
    for _, entry in ipairs(nests) do
        local egg = entry.egg
        if egg and egg.Parent and not espBillboards[egg] then
            local bb = Instance.new("BillboardGui")
            bb.Name = "RSE_ESP"
            bb.AlwaysOnTop = true
            bb.Size = UDim2.new(0, 120, 0, 40)
            bb.StudsOffset = Vector3.new(0, 3.5, 0)
            bb.Adornee = egg
            bb.Parent = egg

            local bg = Instance.new("Frame", bb)
            bg.Size = UDim2.fromScale(1, 1)
            bg.BackgroundColor3 = Color3.fromRGB(12, 12, 18)
            bg.BackgroundTransparency = 0.3
            bg.BorderSizePixel = 0
            Instance.new("UICorner", bg).CornerRadius = UDim.new(0, 6)

            local tName = Instance.new("TextLabel", bg)
            tName.Size = UDim2.new(1, -4, 0.52, 0)
            tName.Position = UDim2.new(0, 2, 0, 0)
            tName.BackgroundTransparency = 1
            tName.TextColor3 = VARIANT_COLOR[entry.variant] or Color3.new(1,1,1)
            tName.TextScaled = true
            tName.Font = Enum.Font.GothamBold
            tName.Text = entry.petName

            local tSub = Instance.new("TextLabel", bg)
            tSub.Size = UDim2.new(1, -4, 0.42, 0)
            tSub.Position = UDim2.new(0, 2, 0.56, 0)
            tSub.BackgroundTransparency = 1
            tSub.TextColor3 = Color3.fromRGB(160, 240, 140)
            tSub.TextScaled = true
            tSub.Font = Enum.Font.Gotham
            tSub.Text = string.format("💰%.1fM • %s", entry.income, entry.biome)

            espBillboards[egg] = bb
        end
    end
end

local function clearESP()
    for _, bb in pairs(espBillboards) do bb:Destroy() end
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

-- ─── UI ───────────────────────────────────────────────────────────────────────
local gui = Instance.new("ScreenGui")
gui.Name = "RSENestInspector"
gui.ResetOnSpawn = false
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent = (pcall(function() return gethui() end) and gethui()) or lp.PlayerGui

-- main panel 262 × 390
local panel = Instance.new("Frame", gui)
panel.Size = UDim2.new(0, 262, 0, 390)
panel.Position = UDim2.new(0.5, -131, 0.5, -195)
panel.BackgroundColor3 = Color3.fromRGB(13, 11, 22)
panel.BorderSizePixel = 0
panel.Active = true
panel.Draggable = true
Instance.new("UICorner", panel).CornerRadius = UDim.new(0, 10)
local mainStroke = Instance.new("UIStroke", panel)
mainStroke.Color = Color3.fromRGB(90, 60, 150)
mainStroke.Thickness = 1.5

-- title bar
local titleBar = Instance.new("Frame", panel)
titleBar.Size = UDim2.new(1, 0, 0, 32)
titleBar.BackgroundColor3 = Color3.fromRGB(22, 16, 42)
titleBar.BorderSizePixel = 0
Instance.new("UICorner", titleBar).CornerRadius = UDim.new(0, 10)
-- cover bottom round of title bar
local tFix = Instance.new("Frame", titleBar)
tFix.Size = UDim2.new(1, 0, 0.5, 0); tFix.Position = UDim2.new(0,0,0.5,0)
tFix.BackgroundColor3 = Color3.fromRGB(22,16,42); tFix.BorderSizePixel = 0

local titleLbl = Instance.new("TextLabel", titleBar)
titleLbl.Size = UDim2.new(1,-36,1,0); titleLbl.Position = UDim2.new(0,10,0,0)
titleLbl.BackgroundTransparency = 1
titleLbl.TextColor3 = Color3.fromRGB(210, 185, 255)
titleLbl.TextScaled = true; titleLbl.Font = Enum.Font.GothamBold
titleLbl.Text = "🥚  RSE NestInspector v3"
titleLbl.TextXAlignment = Enum.TextXAlignment.Left

local closeBtn = Instance.new("TextButton", titleBar)
closeBtn.Size = UDim2.new(0,22,0,22); closeBtn.Position = UDim2.new(1,-26,0.5,-11)
closeBtn.BackgroundColor3 = Color3.fromRGB(170,45,45)
closeBtn.Text = "✕"; closeBtn.TextScaled = true; closeBtn.Font = Enum.Font.GothamBold
closeBtn.TextColor3 = Color3.new(1,1,1); closeBtn.BorderSizePixel = 0
Instance.new("UICorner", closeBtn).CornerRadius = UDim.new(0,5)

-- section label
local secLbl = Instance.new("TextLabel", panel)
secLbl.Size = UDim2.new(1,-12,0,18); secLbl.Position = UDim2.new(0,6,0,34)
secLbl.BackgroundTransparency = 1
secLbl.TextColor3 = Color3.fromRGB(110,90,180)
secLbl.TextScaled = true; secLbl.Font = Enum.Font.Gotham
secLbl.Text = "⚔️  Bypass & Steal"; secLbl.TextXAlignment = Enum.TextXAlignment.Left

-- ride info strip
local rideStrip = Instance.new("Frame", panel)
rideStrip.Size = UDim2.new(1,-12,0,20); rideStrip.Position = UDim2.new(0,6,0,54)
rideStrip.BackgroundColor3 = Color3.fromRGB(20,15,38)
rideStrip.BorderSizePixel = 0
Instance.new("UICorner", rideStrip).CornerRadius = UDim.new(0,5)

local rideLbl = Instance.new("TextLabel", rideStrip)
rideLbl.Size = UDim2.fromScale(1,1); rideLbl.BackgroundTransparency = 1
rideLbl.TextColor3 = Color3.fromRGB(150,240,150)
rideLbl.TextScaled = true; rideLbl.Font = Enum.Font.Gotham
rideLbl.Text = "🐾 สัตว์เร็วสุด: กด Scan เพื่อตรวจ"

-- toggle row
local toggleRow = Instance.new("Frame", panel)
toggleRow.Size = UDim2.new(1,-12,0,26); toggleRow.Position = UDim2.new(0,6,0,77)
toggleRow.BackgroundTransparency = 1
local togLayout = Instance.new("UIListLayout", toggleRow)
togLayout.FillDirection = Enum.FillDirection.Horizontal
togLayout.Padding = UDim.new(0,5)

local function makeToggle(parent, lbl, key, cb)
    local btn = Instance.new("TextButton", parent)
    btn.Size = UDim2.new(0, 74, 1, 0)
    btn.BackgroundColor3 = Color3.fromRGB(30,24,50)
    btn.BorderSizePixel = 0; btn.TextScaled = true; btn.Font = Enum.Font.Gotham
    btn.TextColor3 = Color3.fromRGB(155,140,195)
    btn.Text = lbl .. ": OFF"
    Instance.new("UICorner", btn).CornerRadius = UDim.new(0,6)
    btn.MouseButton1Click:Connect(function()
        state[key] = not state[key]
        btn.Text = lbl .. (state[key] and ": ON" or ": OFF")
        btn.BackgroundColor3 = state[key]
            and Color3.fromRGB(50,32,88) or Color3.fromRGB(30,24,50)
        btn.TextColor3 = state[key]
            and Color3.fromRGB(200,170,255) or Color3.fromRGB(155,140,195)
        if cb then cb(state[key]) end
    end)
    return btn
end

makeToggle(toggleRow,"Invinc","invincible",function(on) if on then startInvincible() end end)
makeToggle(toggleRow,"NoClip","noclip",    function(on) if on then startNoclip() end end)
makeToggle(toggleRow,"ESP","esp",          function(on) if on then buildESP() else clearESP() end end)

-- separator
local sep = Instance.new("Frame", panel)
sep.Size = UDim2.new(1,-12,0,1); sep.Position = UDim2.new(0,6,0,107)
sep.BackgroundColor3 = Color3.fromRGB(55,45,85); sep.BorderSizePixel = 0

-- status bar
local statusBar = Instance.new("Frame", panel)
statusBar.Size = UDim2.new(1,-12,0,22); statusBar.Position = UDim2.new(0,6,0,112)
statusBar.BackgroundColor3 = Color3.fromRGB(18,13,34); statusBar.BorderSizePixel = 0
Instance.new("UICorner", statusBar).CornerRadius = UDim.new(0,5)
local statusLbl = Instance.new("TextLabel", statusBar)
statusLbl.Size = UDim2.fromScale(1,1); statusLbl.BackgroundTransparency = 1
statusLbl.TextColor3 = Color3.fromRGB(190,190,210)
statusLbl.TextScaled = true; statusLbl.Font = Enum.Font.Gotham
statusLbl.Text = "พร้อมใช้งาน — กด Scan"

-- scan button
local scanBtn = Instance.new("TextButton", panel)
scanBtn.Size = UDim2.new(1,-12,0,24); scanBtn.Position = UDim2.new(0,6,0,138)
scanBtn.BackgroundColor3 = Color3.fromRGB(42,32,72); scanBtn.BorderSizePixel = 0
scanBtn.TextScaled = true; scanBtn.Font = Enum.Font.GothamBold
scanBtn.TextColor3 = Color3.fromRGB(200,180,255)
scanBtn.Text = "🔍  Scan Nests"
Instance.new("UICorner", scanBtn).CornerRadius = UDim.new(0,6)

-- scroll list
local scroll = Instance.new("ScrollingFrame", panel)
scroll.Size = UDim2.new(1,-8,1,-168); scroll.Position = UDim2.new(0,4,0,166)
scroll.BackgroundTransparency = 1; scroll.BorderSizePixel = 0
scroll.ScrollBarThickness = 3
scroll.ScrollBarImageColor3 = Color3.fromRGB(100,80,160)
scroll.CanvasSize = UDim2.new(0,0,0,0)
scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y

local listLayout = Instance.new("UIListLayout", scroll)
listLayout.Padding = UDim.new(0,5)
local listPad = Instance.new("UIPadding", scroll)
listPad.PaddingLeft = UDim.new(0,3); listPad.PaddingRight = UDim.new(0,3)
listPad.PaddingTop  = UDim.new(0,3)

-- ─── pet viewport ────────────────────────────────────────────────────────────
local function makePetViewport(parent, petName)
    local vp = Instance.new("ViewportFrame", parent)
    vp.Size = UDim2.new(0,50,0,50)
    vp.Position = UDim2.new(0,4,0.5,-25)
    vp.BackgroundColor3 = Color3.fromRGB(18,13,32)
    vp.BorderSizePixel = 0
    Instance.new("UICorner", vp).CornerRadius = UDim.new(0,6)

    local ok, petModels = pcall(function()
        return game:GetService("ReplicatedStorage").Assets.PetModels
    end)
    if not ok or not petModels then return vp end

    local model = petModels:FindFirstChild(petName)
    if not model then
        for _, m in ipairs(petModels:GetChildren()) do
            if m.Name:lower():find(petName:lower(), 1, true) then
                model = m; break
            end
        end
    end
    if not model then return vp end

    local clone = model:Clone()
    clone.Parent = vp
    local cam = Instance.new("Camera", vp)
    vp.CurrentCamera = cam
    local cf, size = clone:GetBoundingBox()
    local dist = math.max(size.X, size.Y, size.Z) * 1.8
    cam.CFrame = CFrame.new(cf.Position + Vector3.new(0, size.Y*0.3, dist), cf.Position)
    return vp
end

-- ─── build mob cards ─────────────────────────────────────────────────────────
local function clearCards()
    for _, c in ipairs(scroll:GetChildren()) do
        if c:IsA("Frame") then c:Destroy() end
    end
end

local function buildCards(entries)
    clearCards()
    if #entries == 0 then
        local empty = Instance.new("TextLabel", scroll)
        empty.Size = UDim2.new(1,0,0,36)
        empty.BackgroundTransparency = 1
        empty.TextColor3 = Color3.fromRGB(120,100,160)
        empty.TextScaled = true; empty.Font = Enum.Font.Gotham
        empty.Text = "ไม่เจอไข่ที่ unlock แล้ว"
        return
    end

    for i, entry in ipairs(entries) do
        local card = Instance.new("Frame", scroll)
        card.Name = "Card" .. i
        card.LayoutOrder = i
        card.Size = UDim2.new(1, 0, 0, 62)
        card.BackgroundColor3 = Color3.fromRGB(20,15,36)
        card.BorderSizePixel = 0
        Instance.new("UICorner", card).CornerRadius = UDim.new(0,8)
        local cStroke = Instance.new("UIStroke", card)
        cStroke.Color = VARIANT_COLOR[entry.variant] or Color3.fromRGB(60,50,100)
        cStroke.Thickness = 1

        makePetViewport(card, entry.petName)

        -- info block
        local info = Instance.new("Frame", card)
        info.Size = UDim2.new(1,-118,1,-6); info.Position = UDim2.new(0,60,0,3)
        info.BackgroundTransparency = 1

        local tName = Instance.new("TextLabel", info)
        tName.Size = UDim2.new(1,0,0,19); tName.BackgroundTransparency = 1
        tName.TextColor3 = VARIANT_COLOR[entry.variant] or Color3.new(1,1,1)
        tName.TextScaled = true; tName.Font = Enum.Font.GothamBold
        tName.Text = entry.petName; tName.TextXAlignment = Enum.TextXAlignment.Left

        local tBiome = Instance.new("TextLabel", info)
        tBiome.Size = UDim2.new(1,0,0,15); tBiome.Position = UDim2.new(0,0,0,21)
        tBiome.BackgroundTransparency = 1
        tBiome.TextColor3 = Color3.fromRGB(120,110,165)
        tBiome.TextScaled = true; tBiome.Font = Enum.Font.Gotham
        tBiome.Text = "📍 " .. entry.biome .. " · " .. entry.variant
        tBiome.TextXAlignment = Enum.TextXAlignment.Left

        local tInc = Instance.new("TextLabel", info)
        tInc.Size = UDim2.new(1,0,0,15); tInc.Position = UDim2.new(0,0,0,38)
        tInc.BackgroundTransparency = 1
        tInc.TextColor3 = Color3.fromRGB(130,230,110)
        tInc.TextScaled = true; tInc.Font = Enum.Font.Gotham
        tInc.Text = string.format("💰 %.1fM/hr", entry.income)
        tInc.TextXAlignment = Enum.TextXAlignment.Left

        -- steal button
        local stealBtn = Instance.new("TextButton", card)
        stealBtn.Size = UDim2.new(0,50,0,28); stealBtn.Position = UDim2.new(1,-56,0.5,-14)
        stealBtn.BackgroundColor3 = Color3.fromRGB(150,45,215)
        stealBtn.BorderSizePixel = 0; stealBtn.TextScaled = true
        stealBtn.Font = Enum.Font.GothamBold; stealBtn.TextColor3 = Color3.new(1,1,1)
        stealBtn.Text = "STEAL"
        Instance.new("UICorner", stealBtn).CornerRadius = UDim.new(0,6)

        local entryRef = entry
        stealBtn.MouseButton1Click:Connect(function()
            if state.stealing then return end
            stealBtn.BackgroundColor3 = Color3.fromRGB(90,25,130)
            stealBtn.Text = "..."
            stealEgg(entryRef, function(msg) statusLbl.Text = msg end)
            task.wait(0.8)
            stealBtn.BackgroundColor3 = Color3.fromRGB(150,45,215)
            stealBtn.Text = "STEAL"
        end)
    end
end

-- ─── scan button ─────────────────────────────────────────────────────────────
local function doScan()
    scanBtn.Text = "⏳ Scanning..."
    task.wait(0.05)

    -- update ride strip
    local petInfo = getFastestOwnPet()
    if petInfo then
        rideLbl.Text = string.format("🐾 เร็วสุด: %s (score %.0f)", petInfo.name, petInfo.score)
    else
        rideLbl.Text = "⚠️ ไม่เจอสัตว์ใน base ของเรา"
    end

    local entries = scanNests()
    buildCards(entries)
    scanBtn.Text = string.format("🔍  Scan  (%d ไข่)", #entries)
    statusLbl.Text = string.format("พบ %d ไข่ — กด STEAL เพื่อขโมย", #entries)

    if state.esp then clearESP(); buildESP() end
end

scanBtn.MouseButton1Click:Connect(doScan)

-- ─── close / minimise ────────────────────────────────────────────────────────
closeBtn.MouseButton1Click:Connect(function()
    TweenService:Create(panel, TweenInfo.new(0.18), {Size=UDim2.new(0,262,0,0)}):Play()
    task.wait(0.2); gui:Destroy(); unfreezeAll()
end)

local miniBtn = Instance.new("TextButton", gui)
miniBtn.Size = UDim2.new(0,34,0,34); miniBtn.Position = UDim2.new(0,6,0.5,-17)
miniBtn.BackgroundColor3 = Color3.fromRGB(22,16,42); miniBtn.BorderSizePixel = 0
miniBtn.TextScaled = true; miniBtn.Font = Enum.Font.GothamBold
miniBtn.TextColor3 = Color3.fromRGB(200,180,255); miniBtn.Text = "🥚"
miniBtn.Visible = false
Instance.new("UICorner", miniBtn).CornerRadius = UDim.new(0,8)
Instance.new("UIStroke", miniBtn).Color = Color3.fromRGB(80,60,140)

miniBtn.MouseButton1Click:Connect(function()
    panel.Visible = true; miniBtn.Visible = false
end)
titleBar.InputBegan:Connect(function(inp)
    if inp.UserInputType == Enum.UserInputType.MouseButton2 then
        panel.Visible = false; miniBtn.Visible = true
    end
end)

-- ─── char respawn ────────────────────────────────────────────────────────────
lp.CharacterAdded:Connect(function(c)
    char = c; hrp = c:WaitForChild("HumanoidRootPart")
    state.invincible = false; state.noclip = false; state.stealing = false
end)

-- ─── auto scan on load ───────────────────────────────────────────────────────
task.delay(1.5, doScan)

-- ready 🥚
