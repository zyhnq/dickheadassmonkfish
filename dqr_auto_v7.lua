-- language: Lua, file: dqr_auto.lua, runtime: Potassium, target: Roblox PC
local source = [==[
-- language: Lua, file: dqr_combat.lua, runtime: Potassium, target: Roblox PC
local source_text, resume = ...
local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local Paths = game:GetService("PathfindingService")
local Run = game:GetService("RunService")
local Http = game:GetService("HttpService")
local Input = game:GetService("UserInputService")
local Teleports = game:GetService("TeleportService")
local player = Players.LocalPlayer
assert(player, "Wait until the client loads.")
assert(game.GameId == 9931749389, "Run this in Dungeon Quest Reborn.")
local remotes = RS:WaitForChild("remotes", 15)
assert(remotes, "DQR remotes were not found.")

local env = getgenv()
if env.dqr_combat_session then env.dqr_combat_session.stop() end
local state_file = "dqr_warrior_state.json"
local saved_state = {}
if type(readfile) == "function" then
    local ok, value = pcall(function() return Http:JSONDecode(readfile(state_file)) end)
    if ok and type(value) == "table" and type(value.enabled) == "boolean" then saved_state = value end
end
local active = saved_state.enabled
if active == nil then active = resume ~= false end
local session = {alive = true, enabled = active,
    options = type(saved_state.options) == "table" and saved_state.options or {},
    metrics = type(saved_state.metrics) == "table" and saved_state.metrics or {}, calls = {}}
local function save_state()
    if type(writefile) ~= "function" then return false end
    return pcall(function()
        writefile(state_file, Http:JSONEncode({enabled = session.enabled, build = "Warrior", spacing = saved_state.spacing,
            options = session.options, metrics = session.metrics}))
    end)
end
save_state()
env.dqr_combat_session = session
local target, path_target, waypoints, waypoint_index
local config = {build = "Warrior", spacing = 7.5, attack_range = 10, cast_range = 70}
if type(saved_state.spacing) == "number" then config.spacing = math.clamp(saved_state.spacing, 6, 12) end
local Policy = {}
function Policy.zero_argument_calls(source)
    local names = {replayDungeon = true, ReturnToLobbyEvent = true}
    local aliases, found = {}, {}
    for variable, initializer in source:gmatch("local%s+([%w_]+)%s*=%s*([^\n]+)") do
        for name in pairs(names) do
            if initializer:find('["\']' .. name .. '["\']')
                or initializer:find("%." .. name .. "[%s;]*$") then aliases[variable] = name end
        end
    end
    for reference in source:gmatch("([%w_%.]+)%s*:%s*FireServer%s*%(%s*%)") do
        local name = aliases[reference] or reference:match("([%w_]+)$")
        if names[name] then found[name] = true end
    end
    return found
end
function Policy.goal(options, metrics, level)
    if tonumber(options.level_goal) and options.level_goal > 0 and level and level >= options.level_goal then return "Level goal reached" end
    if tonumber(options.clear_goal) and options.clear_goal > 0 and metrics.clears >= options.clear_goal then return "Clear goal reached" end
    if tonumber(options.minute_goal) and options.minute_goal > 0 and metrics.active_seconds >= options.minute_goal * 60 then return "Time goal reached" end
end
function Policy.adaptive_index(unlocked, offset)
    return math.max(1, math.min(unlocked, unlocked + math.min(0, offset or 0)))
end
function Policy.record_outcome(metrics, outcome, duration, target_seconds)
    if outcome == "clear" then
        metrics.clears = metrics.clears + 1
        metrics.clear_seconds = metrics.clear_seconds + duration
        metrics.fast_streak = duration <= target_seconds and (metrics.fast_streak + 1) or 0
        metrics.failure_streak = 0
        if metrics.fast_streak >= 2 then metrics.offset = math.min(0, metrics.offset + 1); metrics.fast_streak = 0 end
        if duration > target_seconds * 2 then metrics.offset = math.max(-6, metrics.offset - 1) end
    else
        metrics.failures = metrics.failures + 1
        metrics.failure_streak = metrics.failure_streak + 1
        metrics.fast_streak = 0
        if metrics.failure_streak >= 2 then metrics.offset = math.max(-6, metrics.offset - 1); metrics.failure_streak = 0 end
    end
end
function Policy.inventory_items(data)
    local items = {}
    for _, category in ipairs({{"weapons", "weapon", 8}, {"chests", "chest", 7},
        {"helmets", "helmet", 8}, {"abilities", "ability", 9}}) do
        for key, record in pairs(type(data[category[1]]) == "table" and data[category[1]] or {}) do
            local id = tonumber(tostring(key):sub(category[3]))
            if id and type(record) == "table" then
                local equipped = record.equipped == true
                if type(record.equipped) == "table" then
                    for _, slot in ipairs({"q", "e", "q2", "e2"}) do equipped = equipped or record.equipped[slot] == true end
                end
                items[#items + 1] = {kind = category[2], id = id, key = tostring(key), record = record,
                    equipped = equipped, score = tonumber(category[2] == "weapon" and record.physicalDamage or record.physicalPower) or 0,
                    health = tonumber(record.health) or 0, level = tonumber(record.levelReq) or 0}
            end
        end
    end
    return items
end
function Policy.locked(item, locks)
    local record = item.record
    if record.locked == true or record.favorite == true or record.favourite == true then return true end
    local identities = {item.kind .. ":" .. item.id, tostring(record.UniqueItemID or ""), tostring(record.name or "")}
    for _, lock in ipairs(locks or {}) do
        for _, identity in ipairs(identities) do if identity ~= "" and identity:lower() == tostring(lock):lower() then return true end end
    end
    return false
end
function Policy.best_gear(items, level, locks)
    local best, fixed = {}, {}
    for _, item in ipairs(items) do
        if item.kind ~= "ability" and item.equipped and Policy.locked(item, locks) then
            best[item.kind], fixed[item.kind] = item, true
        end
    end
    for _, item in ipairs(items) do
        if item.kind ~= "ability" and not fixed[item.kind] and item.level <= level
            and (item.equipped or not Policy.locked(item, locks)) then
            local current = best[item.kind]
            if not current or item.score > current.score
                or (item.score == current.score and item.health > current.health)
                or (item.score == current.score and item.health == current.health and item.equipped) then best[item.kind] = item end
        end
    end
    return best
end
function Policy.sale(items, options, level)
    local best = Policy.best_gear(items, math.huge, {})
    local protected, payload, count = {}, {weapon = {}, ability = {}, chest = {}, helmet = {}}, 0
    for _, item in pairs(best) do protected[item.kind .. ":" .. item.id] = true end
    for _, item in pairs(Policy.best_gear(items, level or 0, {})) do protected[item.kind .. ":" .. item.id] = true end
    for _, item in ipairs(items) do
        local record = item.record
        local rarity = type(record.rarity) == "string" and record.rarity:lower() or ""
        local explicitly_unequipped = record.equipped == false
            or (item.kind == "ability" and type(record.equipped) == "table" and not item.equipped)
        if explicitly_unequipped and not item.equipped and not protected[item.kind .. ":" .. item.id]
            and not Policy.locked(item, options.locks) and options.sell_rarities[rarity] == true
            and (item.kind ~= "ability" or options.sell_abilities == true)
            and rarity ~= "legendary" and rarity ~= "ultimate" then
            local unique = type(record.UniqueItemID) == "string" and record.UniqueItemID ~= "" and record.UniqueItemID or "none"
            payload[item.kind][#payload[item.kind] + 1] = tostring(item.id) .. ":" .. unique
            count = count + 1
        end
    end
    return payload, count
end
function Policy.is_buff(name, has_buff_power)
    local buffs = {berserk = true, innervate = true, innerrage = true,
        enhancedinnerrage = true, innerfocus = true, enhancedinnerfocus = true}
    return has_buff_power or buffs[name:lower():gsub("%W", "")] == true
end
function Policy.point_rank(name)
    local ranks = {skillpoints = 100, unspentpoints = 100, availableskillpoints = 100,
        statpoints = 90, availablepoints = 90, pointsavailable = 90, points = 10}
    return ranks[name:lower():gsub("%W", "")]
end
function Policy.choose(candidates, now, distance, danger, limit)
    if danger >= (limit or 0.6) then return nil end
    local best, score
    for _, skill in ipairs(candidates) do
        if skill.cooldown <= 0 and now >= skill.next_ready and distance <= skill.range then
            local value = (skill.buff and 1000000 or skill.damage / math.max(skill.length, 0.5)) + (skill.priority or 0) * 100
                + math.min(now - skill.last_used, 30) * 0.05
            if not score or value > score then best, score = skill, value end
        end
    end
    return best
end
function Policy.observe(pattern, delay, x, z)
    pattern.samples = pattern.samples or {}
    local samples = pattern.samples
    samples[#samples + 1] = {delay = delay, x = x, z = z}
    if #samples > 16 then table.remove(samples, 1) end
    local mean = 0
    for _, sample in ipairs(samples) do mean = mean + sample.delay end
    mean = mean / #samples
    local variance = 0
    for _, sample in ipairs(samples) do variance = variance + (sample.delay - mean)^2 end
    pattern.mean, pattern.sigma = mean, math.sqrt(variance / #samples)
    pattern.count = #samples
end
function Policy.window(pattern, elapsed)
    if not pattern or (pattern.count or 0) < 3 then return false end
    return elapsed >= pattern.mean - math.max(0.6, pattern.sigma * 2)
        and elapsed <= pattern.mean + math.max(0.35, pattern.sigma * 2)
end
function Policy.restore_patterns(data)
    local result = {}
    if type(data) ~= "table" or data.version ~= 1 or type(data.patterns) ~= "table" then return result end
    local count = 0
    for key, old in pairs(data.patterns) do
        if count >= 256 then break end
        if type(key) == "string" and type(old) == "table" and type(old.samples) == "table" then
            local pattern = {}
            for _, sample in ipairs(old.samples) do
                if type(sample) == "table" and type(sample.delay) == "number"
                    and sample.delay >= 0.05 and sample.delay <= 6
                    and type(sample.x) == "number" and math.abs(sample.x) <= 1000
                    and type(sample.z) == "number" and math.abs(sample.z) <= 1000 then
                    Policy.observe(pattern, sample.delay, sample.x, sample.z)
                end
            end
            if pattern.count then result[key] = pattern; count = count + 1 end
        end
    end
    return result
end
function Policy.stat_arguments(source)
    local aliases = {spendSkillPoint = true}
    for variable, initializer in source:gmatch("local%s+([%w_]+)%s*=%s*([^\n]+)") do
        if initializer:find([=[["']spendSkillPoint["']]=])
            or initializer:find("%.spendSkillPoint[%s;]*$") then aliases[variable] = true end
    end
    for reference, arguments in source:gmatch("([%w_%.]+)%s*:%s*FireServer%s*%(([^)\n]*)%)") do
        if aliases[reference] or reference:match("%.spendSkillPoint$") then
            local quote, stat, rest = arguments:match([=[^%s*(["'])([%w_ ]+)%1%s*(.*)$]=])
            if quote then
                local normalized = stat:lower():gsub("%W", "")
                if normalized == "physicalpower" or normalized == "physicaldamage"
                    or normalized == "physical" or normalized == "strength" then
                    if rest:match("^%s*$") then return {stat, n = 1} end
                    if rest:match("^,%s*1%s*$") then return {stat, 1, n = 2} end
                end
            end
        end
    end
end
-- END POLICY
local features = {run_started = nil, outcome = nil, recovery = "Waiting for run", profile = "Balanced",
    inventory = "Gear / selling: current handlers required", telegraphs = "Telegraphs: no verified indicators",
    last_progress = nil, stuck_seconds = 0, last_jump = 0, blocked_targets = {}, death_watch = nil,
    hazards = {}, indicators = setmetatable({}, {__mode = "k"}), safe_zone = nil}
session.features = features
for _, name in ipairs({"clears", "failures", "deaths", "clear_seconds", "active_seconds", "fast_streak", "failure_streak",
    "offset", "cast_started", "cast_failed", "recoveries", "observed_xp"}) do
    local value = session.metrics[name]
    session.metrics[name] = type(value) == "number" and value == value and math.abs(value) < 1000000000 and value or 0
end
session.metrics.offset = math.clamp(session.metrics.offset, -6, 0)
for _, name in ipairs({"level_goal", "clear_goal", "minute_goal"}) do
    local value = tonumber(session.options[name])
    session.options[name] = value and value >= 0 and value < 1000000 and value or 0
end
session.options.profile = ({Aggressive = true, Balanced = true, Conservative = true})[session.options.profile]
    and session.options.profile or "Balanced"
session.options.abilities = type(session.options.abilities) == "table" and session.options.abilities or {}
session.options.locks = type(session.options.locks) == "table" and session.options.locks or {}
session.options.sell_rarities = type(session.options.sell_rarities) == "table" and session.options.sell_rarities or {}
session.options.auto_equip = session.options.auto_equip ~= false
session.options.auto_replay = session.options.auto_replay ~= false
session.options.auto_sell = session.options.auto_sell == true
features.profile = session.options.profile
if session.metrics.job ~= game.JobId then session.metrics.job, session.metrics.round = game.JobId, 0 end
session.metrics.round = tonumber(session.metrics.round) or 0
session.metrics.boss_records = type(session.metrics.boss_records) == "table" and session.metrics.boss_records or {}
save_state()
local enemies = {}
local controlled, original_rotate
local steering = Vector3.zero
local path_goal, path_origin
local progress_time, stalled = 0, false
local function release_movement()
    if controlled and controlled.Parent then
        controlled:Move(Vector3.zero, false)
        controlled.AutoRotate = original_rotate
    end
    controlled, original_rotate = nil, nil
    steering = Vector3.zero
end
local last_path, last_swing = 0, 0
local attempts = setmetatable({}, {__mode = "k"})
local pending_cast
local note = "Paused: enter a dungeon and start the run normally."
local ability_note, learning_note, stat_note = "Abilities waiting", "Observing attack signals", "Finding stat handler"
local active_attacks, watched_rigs = {}, {}
local learned = {patterns = {}}
local pattern_file = "dqr_warrior_patterns.json"
if type(readfile) == "function" then
    local ok, data = pcall(function() return Http:JSONDecode(readfile(pattern_file)) end)
    if ok then learned.patterns = Policy.restore_patterns(data) end
end
local dirty_patterns = false
local function save_patterns()
    if not dirty_patterns or type(writefile) ~= "function" then return end
    local ok = pcall(function()
        writefile(pattern_file, Http:JSONEncode({version = 1, patterns = learned.patterns}))
    end)
    if ok then dirty_patterns = false end
end
local movement_note = "Movement paused"
local path_note = "No route yet"
local render_name = "DQRWarriorMovement"
local connections = {}
local lobby_note = ""
local lobby_place = game.PlaceId == 77649408247578
local queue_code = queue_on_teleport or queueonteleport
if type(queue_code) ~= "function" and type(syn) == "table" then
    queue_code = syn.queue_on_teleport
end
connections[#connections + 1] = player.OnTeleport:Connect(function(state)
    if state == Enum.TeleportState.Started and session.alive and session.enabled
        and type(queue_code) == "function" and type(source_text) == "string" then
        local quoted = string.format("%q", source_text)
        local queued = "local s=" .. quoted .. "; local f=assert(loadstring(s)); f(s,true)"
        local ok, err = pcall(queue_code, queued)
        if not ok then warn("DQR resume failed: " .. tostring(err)) end
    end
end)

local gui = Instance.new("ScreenGui")
gui.Name = "DQRCombatControls"
gui.ResetOnSpawn = false
gui.Parent = player:WaitForChild("PlayerGui")
local frame = Instance.new("Frame", gui)
frame.Size = UDim2.fromOffset(460, 496)
frame.Position = UDim2.fromOffset(20, 120)
frame.BackgroundColor3 = Color3.fromRGB(24, 29, 38)
local function label(text, y, height)
    local item = Instance.new("TextLabel", frame)
    item.Position = UDim2.fromOffset(12, y)
    item.Size = UDim2.new(1, -24, 0, height)
    item.BackgroundTransparency = 1
    item.TextColor3 = Color3.new(1, 1, 1)
    item.TextSize = 15
    item.TextWrapped = true
    item.Text = text
    return item
end
label("DQR Warrior auto v7", 8, 24)
local status = label(note, 35, 112)
local function button(text, y, callback)
    local item = Instance.new("TextButton", frame)
    item.Position = UDim2.fromOffset(12, y)
    item.Size = UDim2.new(1, -24, 0, 34)
    item.BackgroundColor3 = Color3.fromRGB(44, 61, 80)
    item.TextColor3 = Color3.new(1, 1, 1)
    item.TextSize = 15
    item.Text = text
    connections[#connections + 1] = item.Activated:Connect(callback)
    return item
end
local function character_parts()
    local character = player.Character
    if not character then return end
    local humanoid = character:FindFirstChildOfClass("Humanoid")
    local root = character:FindFirstChild("HumanoidRootPart")
    if humanoid and root and humanoid.Health > 0 then
        return character, humanoid, root
    end
end
local function halt()
    release_movement()
    target, waypoints, path_target = nil, nil, nil
    path_goal, path_origin = nil, nil
    progress_time, stalled = 0, false
end
function session.stop()
    session.alive, session.enabled = false, false
    save_patterns()
    Run:UnbindFromRenderStep(render_name)
    halt()
    for _, connection in ipairs(connections) do connection:Disconnect() end
    for _, connection in pairs(watched_rigs) do connection:Disconnect() end
    gui:Destroy()
end
local toggle
function features.set_enabled(enabled, reason)
    if not session.alive then return end
    session.enabled = enabled
    save_state()
    if toggle then toggle.Text = session.enabled and "Pause automation [F8]" or "Start automation [F8]" end
    lobby_note = ""
    session.lobby_attempted, session.dungeon_start_sent = false, false
    if not session.enabled then halt(); note = reason or "Paused" end
end
toggle = button(session.enabled and "Pause automation [F8]" or "Start automation [F8]", 156, function()
    features.set_enabled(not session.enabled)
end)
connections[#connections + 1] = Input.InputBegan:Connect(function(input)
    if input.KeyCode == Enum.KeyCode.F8 then
        features.set_enabled(not session.enabled, "Paused with F8")
    end
end)

local evasive = true
local dodge_button
dodge_button = button("Enemy spacing: ON", 198, function()
    evasive = not evasive
    dodge_button.Text = evasive and "Enemy spacing: ON" or "Enemy spacing: OFF"
end)
button("Copy lobby, gear and attack handlers", 240, function()
    if session.exporting then return end
    if type(decompile) ~= "function" or type(setclipboard) ~= "function" then
        note = "Export requires decompile and setclipboard."
        return
    end
    session.exporting = true
    task.spawn(function()
        local output = {"DQR CONTROL SOURCE", "PlaceId: " .. game.PlaceId}
        local words = {"createLobby", "joinDungeon", "startDungeon", "replayDungeon",
            "equipItem", "upgradeItem", "sellItemEvent", "getData", "reloadInvy",
            "spendSkillPoint", "bossSpecficEvents", "mapSpecificEvent", "golemClientEvents",
            "sanadaClientEvents", "northernBossSpecficEvents", "gildedBossSpecficEvents"}
        local roots = {player.PlayerGui, player.PlayerScripts, RS, game:GetService("ReplicatedFirst")}
        local seen, bytes, hits, failures = {}, 0, 0, 0
        for _, root in ipairs(roots) do
            for _, item in ipairs(root:GetDescendants()) do
                if not session.alive then return end
                if not seen[item] and (item:IsA("LocalScript") or item:IsA("ModuleScript")) then
                    seen[item] = true
                    local ok, source = pcall(decompile, item)
                    if ok and type(source) == "string" then
                        local relevant = false
                        for _, word in ipairs(words) do
                            if source:find(word, 1, true) then relevant = true; break end
                        end
                        if item.Name:lower():find("replay", 1, true) or item.Name:lower():find("menu", 1, true) then relevant = true end
                        if relevant then
                            if bytes + #source <= 900000 then
                                output[#output + 1] = "\n=== " .. item:GetFullName() .. " ===\n" .. source
                                bytes, hits = bytes + #source, hits + 1
                            else
                                output[#output + 1] = "SIZE LIMIT: " .. item:GetFullName()
                            end
                        end
                    else
                        failures = failures + 1
                    end
                    task.wait()
                end
            end
        end
        output[#output + 1] = "Matches: " .. hits .. "; failures: " .. failures
        local report = table.concat(output, "\n")
        if type(writefile) == "function" then pcall(writefile, "dqr_control_source.txt", report) end
        local ok, err = pcall(setclipboard, report)
        note = ok and ("EXPORT COMPLETE: " .. hits .. " scripts copied; starts DQR CONTROL SOURCE") or tostring(err)
        session.exporting = false
    end)
end)
button("Copy enemy details", 282, function()
    if type(setclipboard) ~= "function" then note = "Clipboard unavailable"; return end
    if session.enemy_report then
        local ok, err = pcall(function() setclipboard(session.enemy_report()) end)
        note = ok and "Enemy details copied. Paste into chat." or tostring(err)
    end
end)
local spacing_button
spacing_button = button("Spacing: " .. config.spacing .. " studs — click to change", 324, function()
    local choices = {6, 7.5, 9, 11}
    local next_value = choices[1]
    for _, value in ipairs(choices) do
        if value > config.spacing + 0.01 then next_value = value; break end
    end
    config.spacing, saved_state.spacing = next_value, next_value
    save_state()
    spacing_button.Text = "Spacing: " .. next_value .. " studs — click to change"
end)
button("Dashboard / settings", 366, function()
    if features.toggle_settings then features.toggle_settings() end
end)
button("Reset session counters / goals", 408, function()
    if features.reset then features.reset() end
end)
button("Close and stop", 450, function()
    session.enabled = false
    save_state()
    save_patterns()
    session.stop()
end)

local health_names = {"Health", "health", "HP", "hp", "currentHealth"}
local excluded = {templates = true, enemypool = true, vfxpool = true, sfxpool = true}
local function excluded_model(model)
    local node = model
    while node and node ~= workspace do
        if excluded[node.Name:lower()] then return true end
        if node:IsA("Model") and Players:GetPlayerFromCharacter(node) then return true end
        node = node.Parent
    end
    return node ~= workspace
end
local function enemy_root(model)
    if not model.Parent or not model:IsDescendantOf(workspace) then return end
    local humanoid = model:FindFirstChildOfClass("Humanoid")
    local health
    if humanoid then
        health = humanoid.Health
    else
        for _, name in ipairs(health_names) do
            local value = model:GetAttribute(name)
            local child = model:FindFirstChild(name)
            if typeof(value) == "number" then health = value; break end
            if child and (child:IsA("NumberValue") or child:IsA("IntValue")) then
                health = child.Value; break
            end
        end
    end
    if not health or health <= 0 then return end
    local root = model:FindFirstChild("HumanoidRootPart") or model.PrimaryPart
        or model:FindFirstChild("RootPart") or model:FindFirstChild("Torso")
        or model:FindFirstChildWhichIsA("BasePart", true)
    if root and root:IsA("BasePart") then return root end
end
local function refresh_enemies()
    local result, seen = {}, {}
    -- Discover live rigs anywhere in Workspace, including nested enemy containers.
    for _, item in ipairs(workspace:GetDescendants()) do
        local model
        if item:IsA("Humanoid") and item.Parent:IsA("Model") then
            model = item.Parent
        elseif item:IsA("Model") then
            -- Custom-health models need an enemy/dungeon ancestor to establish membership.
            local node = item.Parent
            while node and node ~= workspace do
                local name = node.Name:lower()
                if name == "enemies" or name == "enemyfolder" or name == "dungeon" then
                    model = item; break
                end
                node = node.Parent
            end
        end
        if model and not seen[model] and not excluded_model(model) then
            seen[model] = true
            if enemy_root(model) then result[#result + 1] = model end
        end
    end
    enemies = result
end

function session.enemy_report()
    local _, humanoid, root = character_parts()
    local output = {"DQR ENEMY DETAILS", "PlaceId: " .. game.PlaceId,
        "Detected: " .. #enemies, "Lobby status: " .. lobby_note,
        "Movement: " .. movement_note, "Route: " .. path_note,
        "Abilities: " .. ability_note, "Learning: " .. learning_note, "Stats: " .. stat_note}
    if root and humanoid then
        output[#output + 1] = "Root anchored: " .. tostring(root.Anchored)
        output[#output + 1] = "WalkSpeed: " .. tostring(humanoid.WalkSpeed)
        output[#output + 1] = "PlatformStand: " .. tostring(humanoid.PlatformStand)
        output[#output + 1] = "Seated: " .. tostring(humanoid.Sit)
        output[#output + 1] = "MoveDirection: " .. tostring(humanoid.MoveDirection)
        output[#output + 1] = "Velocity: " .. tostring(root.AssemblyLinearVelocity)
    end
    local nearby = {}
    for _, item in ipairs(workspace:GetDescendants()) do
        if item:IsA("Model") and not excluded_model(item) then
            local part = item.PrimaryPart or item:FindFirstChildWhichIsA("BasePart")
            if part and root then
                local distance = (part.Position - root.Position).Magnitude
                if distance < 150 then nearby[#nearby + 1] = {model = item, distance = distance} end
            end
        end
    end
    table.sort(nearby, function(a, b) return a.distance < b.distance end)
    for index, record in ipairs(nearby) do
        if index > 40 then break end
        local model = record.model
        output[#output + 1] = string.format("\n%s [%.1f studs]", model:GetFullName(), record.distance)
        for key, value in pairs(model:GetAttributes()) do
            output[#output + 1] = "  attribute " .. key .. "=" .. tostring(value)
        end
        for n, child in ipairs(model:GetChildren()) do
            if n > 25 then output[#output + 1] = "  additional children omitted"; break end
            local detail = ""
            if child:IsA("Humanoid") then detail = " health=" .. child.Health end
            if child:IsA("NumberValue") or child:IsA("IntValue") then detail = " value=" .. child.Value end
            output[#output + 1] = "  " .. child.Name .. " [" .. child.ClassName .. "]" .. detail
        end
    end
    return table.concat(output, "\n")
end

-- Public lobby API reference:
-- https://scriptblox.com/raw/Dungeon-Quest-Reborn-open-source-lobby-ai-224225
local progression = {
    {1, "Desert Temple", "Easy"}, {6, "Desert Temple", "Medium"},
    {12, "Desert Temple", "Hard"}, {20, "Desert Temple", "Insane"},
    {27, "Desert Temple", "Nightmare"}, {33, "Winter Outpost", "Easy"},
    {40, "Winter Outpost", "Medium"}, {45, "Winter Outpost", "Hard"},
    {50, "Winter Outpost", "Insane"}, {55, "Winter Outpost", "Nightmare"},
    {60, "Pirate Island", "Insane"}, {65, "Pirate Island", "Nightmare"},
    {70, "King's Castle", "Insane"}, {75, "King's Castle", "Nightmare"},
    {80, "The Underworld", "Insane"}, {85, "The Underworld", "Nightmare"},
    {90, "Samurai Palace", "Insane"}, {95, "Samurai Palace", "Nightmare"},
    {100, "The Canals", "Insane"}, {105, "The Canals", "Nightmare"},
    {110, "Ghastly Harbor", "Insane"}, {115, "Ghastly Harbor", "Nightmare"},
    {120, "Steampunk Sewers", "Insane"}, {125, "Steampunk Sewers", "Nightmare"},
    {140, "Orbital Outpost", "Insane"}, {146, "Orbital Outpost", "Nightmare"},
    {150, "Volcanic Chambers", "Insane"}, {155, "Volcanic Chambers", "Nightmare"},
}
local function own_lobby()
    local games = workspace:FindFirstChild("games")
    local folder = games and games:FindFirstChild("inLobby")
    return folder and folder:FindFirstChild(player.Name)
end
task.spawn(function()
    while session.alive do
        if session.enabled and lobby_place and session.options.auto_equip and not features.initial_inventory_done then
            lobby_note = "Preparing inventory and Warrior gear"
        elseif session.enabled and lobby_place and not session.lobby_attempted and not session.lobby_busy then
            local stats = player:FindFirstChild("leaderstats")
            local level = stats and stats:FindFirstChild("Level")
            if not level then
                lobby_note = "Waiting for leaderstats.Level"
            else
                session.lobby_attempted, session.lobby_busy = true, true
                local ok, err = pcall(function()
                    if not player.Character and not workspace:FindFirstChild(player.Name) then
                        local load = remotes:FindFirstChild("loadPlayerCharacter")
                        assert(load and load:IsA("RemoteEvent"), "Character not loaded")
                        lobby_note = "Loading lobby character"
                        load:FireServer()
                        local deadline = os.clock() + 10
                        while not character_parts() and os.clock() < deadline and session.alive and session.enabled do
                            task.wait(0.2)
                        end
                        if not session.alive or not session.enabled then return end
                        assert(character_parts(), "Lobby character did not load")
                    end
                    local unlocked = 1
                    for index, row in ipairs(progression) do
                        if level.Value >= row[1] then unlocked = index else break end
                    end
                    local chosen = progression[Policy.adaptive_index(unlocked, session.metrics.offset)]
                    local goal = Policy.goal(session.options, session.metrics, level.Value)
                    if goal then features.set_enabled(false, goal); return end
                    session.options.selection = {dungeon = chosen[2], difficulty = chosen[3]}
                    save_state()
                    lobby_note = "Level " .. level.Value .. ": " .. chosen[2] .. " / " .. chosen[3]
                    if not own_lobby() then
                        local create = remotes:FindFirstChild("createLobby")
                        assert(create and create:IsA("RemoteFunction"), "createLobby unavailable")
                        lobby_note = lobby_note .. " — requesting lobby"
                        -- Minimum level 0, Hardcore off, private on, Wave Defense off.
                        local result = create:InvokeServer(chosen[2], chosen[3], 0, false, true, false)
                        if not session.alive or not session.enabled then return end
                        local deadline = os.clock() + 10
                        while not own_lobby() and os.clock() < deadline and session.alive and session.enabled do
                            task.wait(0.2)
                        end
                        if not session.alive or not session.enabled then return end
                        assert(own_lobby(), "Lobby not confirmed; server returned " .. tostring(result))
                    end
                    lobby_note = "Lobby confirmed — requesting start"
                    task.wait(1)
                    if not session.alive or not session.enabled then return end
                    remotes.startDungeon:FireServer()
                    lobby_note = "Start requested — waiting for teleport"
                    if type(queue_code) ~= "function" or type(source_text) ~= "string" then
                        lobby_note = lobby_note .. "; run script again inside dungeon"
                    end
                end)
                session.lobby_busy = false
                if not ok then lobby_note = "Lobby error: " .. tostring(err) end
            end
        elseif session.enabled and not lobby_place and not session.dungeon_start_sent then
            local started = workspace:FindFirstChild("dungeonStarted")
            local start = remotes:FindFirstChild("changeStartValue")
            if workspace:FindFirstChild("dungeon") and started and start then
                session.dungeon_start_sent = true
                if started.Value == false then
                    local ok, err = pcall(function() start:FireServer() end)
                    if not ok then note = "Dungeon start error: " .. tostring(err) end
                end
            end
        end
        task.wait(0.5)
    end
end)

local function find_target(root)
    local nearest, distance = nil, math.huge
    for _, model in ipairs(enemies) do
        local part = enemy_root(model)
        if part and (features.blocked_targets[model] or 0) <= os.clock() then
            local candidate = (part.Position - root.Position).Magnitude
            if candidate < distance then nearest, distance = model, candidate end
        end
    end
    local current = target and enemy_root(target)
    if current and (features.blocked_targets[target] or 0) <= os.clock()
        and (current.Position - root.Position).Magnitude <= distance * 1.4 then
        return target
    end
    return nearest
end

local function flat(vector)
    return Vector3.new(vector.X, 0, vector.Z)
end
local function ray_params(character)
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    local exclude = {character}
    for _, model in ipairs(enemies) do exclude[#exclude + 1] = model end
    params.FilterDescendantsInstances = exclude
    params.RespectCanCollide = true
    return params
end
local function clear_path(root, destination, params)
    return workspace:Raycast(root.Position, destination - root.Position, params) == nil
end

function features.level()
    local stats = player:FindFirstChild("leaderstats")
    local level = stats and stats:FindFirstChild("Level")
    return level and tonumber(level.Value)
end
function features.rpc(remote, ...)
    features.inflight = features.inflight or {}
    if features.inflight[remote] then return nil, "Request still pending" end
    local arguments, result, finished = table.pack(...), nil, false
    features.inflight[remote] = true
    task.spawn(function()
        result = table.pack(pcall(remote.InvokeServer, remote, table.unpack(arguments, 1, arguments.n)))
        finished, features.inflight[remote] = true, nil
    end)
    local deadline = os.clock() + 12
    while session.alive and session.enabled and not finished and os.clock() < deadline do task.wait(0.05) end
    if not finished then return nil, "Request pending or paused" end
    if not result[1] then return nil, tostring(result[2]) end
    return result[2], result[3]
end
function features.inventory_snapshot()
    local remote = remotes:FindFirstChild("reloadInvy")
    if not remote or not remote:IsA("RemoteFunction") then return nil, "reloadInvy unavailable" end
    local data, err = features.rpc(remote)
    if type(data) ~= "table" or type(data.weapons) ~= "table" then return nil, err or "Inventory not ready" end
    return data
end
function features.observe_inventory(data)
    if not session.alive then return {} end
    local items = Policy.inventory_items(data)
    local seen = session.metrics.seen_items
    if type(seen) ~= "table" then seen = {}; session.metrics.seen_items = seen end
    local baseline = session.metrics.inventory_seeded == true
    for _, item in ipairs(items) do
        local record = item.record
        local identity = type(record.UniqueItemID) == "string" and record.UniqueItemID ~= "" and record.UniqueItemID
            or (item.kind .. ":" .. item.id)
        if baseline and not seen[identity] and type(session.options.drop_goal) == "string"
            and session.options.drop_goal ~= "" and type(record.name) == "string"
            and record.name:lower() == session.options.drop_goal:lower() then
            features.set_enabled(false, "Drop goal reached: " .. record.name)
        end
        seen[identity] = true
    end
    session.metrics.inventory_seeded = true
    local count = 0
    for _ in pairs(seen) do count = count + 1 end
    if count > 2000 then
        session.metrics.seen_items = {}
        session.metrics.inventory_seeded = false
    end
    return items
end
function features.inventory_pass()
    if features.inventory_busy then return end
    features.inventory_busy = true
    local ok, err = pcall(function()
        local data, error_text = features.inventory_snapshot()
        assert(data, error_text)
        local items = features.observe_inventory(data)
        if not session.enabled then return end
        if session.options.auto_equip then
            for _, kind in ipairs({"weapon", "chest", "helmet"}) do
                local best = Policy.best_gear(items, features.level() or 0, session.options.locks)[kind]
                if best and not best.equipped then
                    local equip = remotes:FindFirstChild("equipItem")
                    assert(equip and equip:IsA("RemoteFunction"), "equipItem unavailable")
                    local accepted, equip_error = features.rpc(equip, kind, best.id)
                    assert(accepted, equip_error or "Equipment request rejected")
                    local refreshed, refresh_error = features.inventory_snapshot()
                    assert(refreshed, refresh_error)
                    items = features.observe_inventory(refreshed)
                    local confirmed = false
                    for _, item in ipairs(items) do
                        if item.kind == kind and item.id == best.id and item.equipped then confirmed = true; break end
                    end
                    assert(confirmed, "Equipment update unconfirmed")
                end
            end
        end
        if session.enabled and session.options.auto_sell then
            -- Re-fetch immediately before constructing a sale, after any equipment changes.
            local refreshed, refresh_error = features.inventory_snapshot()
            assert(refreshed, refresh_error)
            items = features.observe_inventory(refreshed)
            if not session.enabled then return end
            local level = features.level()
            assert(level, "Waiting for level before selling")
            local payload, count = Policy.sale(items, session.options, level)
            if count > 0 then
                local sell = remotes:FindFirstChild("sellItemEvent")
                assert(sell and sell:IsA("RemoteEvent"), "sellItemEvent unavailable")
                sell:FireServer(payload)
                task.wait(0.8)
                local verified = features.inventory_snapshot()
                local remaining = verified and Policy.inventory_items(verified)
                local unresolved = not remaining
                for _, item in ipairs(remaining or {}) do
                    for _, identity in ipairs(payload[item.kind]) do
                        local unique = type(item.record.UniqueItemID) == "string" and item.record.UniqueItemID ~= "" and item.record.UniqueItemID or "none"
                        if identity == tostring(item.id) .. ":" .. unique then unresolved = true end
                    end
                end
                if unresolved then
                    session.options.auto_sell = false
                    save_state()
                    error("Sale not confirmed; automatic selling paused")
                end
            end
        end
        features.inventory = "Inventory checked: " .. #items .. " items; Warrior gear / locks applied"
    end)
    features.initial_inventory_done, features.inventory_busy = true, false
    if not ok then features.inventory = "Inventory: " .. tostring(err) end
end
local inventory_update = remotes:FindFirstChild("updateLocalInventoryTable")
if inventory_update and inventory_update:IsA("RemoteEvent") then
    connections[#connections + 1] = inventory_update.OnClientEvent:Connect(function(data)
        if type(data) == "table" and type(data.weapons) == "table" then
            features.observe_inventory(data)
            features.inventory_due = true
        end
    end)
end
task.spawn(function()
    local last = -math.huge
    while session.alive do
        if session.enabled and (not features.initial_inventory_done or features.inventory_due or os.clock() - last >= 15) then
            local character = player.Character
            local busy = character and character:FindFirstChild("busyCasting")
            if not busy or not busy.Value or features.outcome then
                features.inventory_due, last = false, os.clock()
                features.inventory_pass()
                save_state()
            end
        end
        task.wait(1)
    end
end)

function features.finish(outcome)
    if not session.alive or lobby_place or features.outcome then return end
    local token = game.JobId .. "/" .. session.metrics.round
    if session.metrics.last_outcome == token then return end
    session.metrics.last_outcome = token
    local duration = math.max(0, os.time() - (features.run_started or os.time()))
    Policy.record_outcome(session.metrics, outcome, duration, 180)
    features.outcome = {kind = outcome, at = os.clock(), attempts = 0}
    features.inventory_due = true
    features.recovery = outcome == "clear" and "Clear recorded; collecting inventory" or "Failure recorded; preparing recovery"
    halt()
    save_state()
end
for name, outcome in pairs({loadCompleteGui = "clear", loadFailedGui = "failure"}) do
    local remote = remotes:FindFirstChild(name)
    if remote and remote:IsA("RemoteEvent") then
        connections[#connections + 1] = remote.OnClientEvent:Connect(function() features.finish(outcome) end)
    end
end
function features.visible(object)
    local current = object
    while current and current ~= gui.Parent do
        if current:IsA("GuiObject") and not current.Visible then return false end
        if current:IsA("ScreenGui") and not current.Enabled then return false end
        current = current.Parent
    end
    return current == gui.Parent
end
function features.activate(object)
    if not object then return false end
    local button = object:IsA("GuiButton") and object or object:FindFirstChildWhichIsA("GuiButton", true)
    if not button or not features.visible(button) or type(firesignal) ~= "function" then return false end
    local event = button.Activated
    if type(getconnections) == "function" then
        local ok, listeners = pcall(getconnections, button.MouseButton1Click)
        if ok and #listeners > 0 then event = button.MouseButton1Click end
    end
    local ok = pcall(firesignal, event)
    return ok
end
function features.return_lobby()
    local outcome = features.outcome
    if not outcome or not session.enabled or outcome.fallback_attempted then return end
    outcome.fallback_attempted = true
    save_state()
    save_patterns()
    features.recovery = "Returning to lobby for a fresh dungeon"
    local ok, err = pcall(Teleports.Teleport, Teleports, 77649408247578, player)
    if not ok then features.recovery = "Lobby teleport failed: " .. tostring(err) end
end
connections[#connections + 1] = Teleports.TeleportInitFailed:Connect(function(who, _, message)
    if who == player and features.outcome then features.recovery = "Teleport not completed: " .. tostring(message) end
end)
function features.recover()
    local outcome = features.outcome
    if not outcome or not session.enabled or not session.options.auto_replay or features.inventory_busy
        or os.clock() - outcome.at < 8 or outcome.fallback_attempted then return end
    if outcome.attempts >= 3 then
        if outcome.last_attempt and os.clock() - outcome.last_attempt >= 15 then features.return_lobby() end
        return
    end
    if outcome.last_attempt and os.clock() - outcome.last_attempt < 5 then return end
    local player_gui = player:FindFirstChildOfClass("PlayerGui")
    if not player_gui then return end
    local confirmation_name = outcome.action == "return" and "ReturnConfirmation" or "ReplayConfirmation"
    local confirmation = player_gui:FindFirstChild(confirmation_name)
    local confirm = confirmation and confirmation:FindFirstChild("confirm", true)
    if confirm and features.activate(confirm) then
        outcome.attempts, outcome.last_attempt = outcome.attempts + 1, os.clock()
        features.recovery = "Native recovery confirmation dispatched"
        return
    end
    local prefer_return = outcome.kind ~= "clear" or session.metrics.offset < 0
    local command = prefer_return and "ReturnToLobbyEvent" or "replayDungeon"
    if not session.calls[command] then command = session.calls.replayDungeon and "replayDungeon" or command end
    if session.calls[command] then
        local remote = remotes:FindFirstChild(command)
        if remote and remote:IsA("RemoteEvent") then
            remote:FireServer()
            outcome.attempts, outcome.last_attempt = 3, os.clock()
            features.recovery = command .. " requested; waiting for server"
            return
        end
    end
    local chosen, role
    if prefer_return then
        for _, object in ipairs(player_gui:GetDescendants()) do
            if object:IsA("GuiButton") and features.visible(object) then
                local parent = object.Parent
                local text = object:IsA("TextButton") and object.Text:lower() or ""
                if parent then
                    for _, label in ipairs(parent:GetChildren()) do
                        if label:IsA("TextLabel") then text = text .. " " .. label.Text:lower() end
                    end
                end
                local dialog = player_gui:FindFirstChild("ReturnConfirmation")
                local replay_dialog = player_gui:FindFirstChild("ReplayConfirmation")
                if not (dialog and object:IsDescendantOf(dialog)) and not (replay_dialog and object:IsDescendantOf(replay_dialog))
                    and text:find("return to lobby", 1, true) then chosen, role = object, "return"; break end
            end
        end
    end
    if not chosen then
        local menu = player_gui:FindFirstChild("Menu")
        chosen, role = menu and menu:FindFirstChild("replayButton", true), "replay"
    end
    if chosen and features.activate(chosen) then
        outcome.action, outcome.last_attempt, outcome.attempts = role, os.clock(), outcome.attempts + 1
        features.recovery = "Native " .. role .. " control dispatched"
    else
        features.recovery = "Recovery waiting for visible native controls / current handler"
        if os.clock() - outcome.at >= 20 then features.return_lobby() end
    end
end

function features.reset()
    for _, name in ipairs({"clears", "failures", "deaths", "clear_seconds", "active_seconds", "fast_streak", "failure_streak",
        "offset", "cast_started", "cast_failed", "recoveries", "observed_xp"}) do session.metrics[name] = 0 end
    session.options.level_goal, session.options.clear_goal, session.options.minute_goal, session.options.drop_goal = 0, 0, 0, ""
    features.recovery = "Session counters and goals reset"
    for key, input in pairs(features.goal_inputs or {}) do input.Text = key == "drop_goal" and "" or "0" end
    if not session.enabled then note = "Goals reset; press F8 to resume" end
    save_state()
end
function features.build_settings()
    local panel = Instance.new("Frame", gui)
    panel.Name, panel.Visible = "DashboardSettings", false
    panel.AnchorPoint = Vector2.new(0.5, 0.5)
    panel.Position, panel.Size = UDim2.fromScale(0.5, 0.5), UDim2.fromOffset(530, 560)
    panel.BackgroundColor3 = Color3.fromRGB(20, 25, 34)
    local close = Instance.new("TextButton", panel)
    close.Text, close.TextSize = "Close settings", 14
    close.Position, close.Size = UDim2.new(1, -152, 0, 6), UDim2.fromOffset(140, 28)
    close.BackgroundColor3, close.TextColor3 = Color3.fromRGB(44, 65, 87), Color3.new(1, 1, 1)
    connections[#connections + 1] = close.Activated:Connect(function() panel.Visible = false end)
    local scroll = Instance.new("ScrollingFrame", panel)
    scroll.Position, scroll.Size = UDim2.fromOffset(8, 40), UDim2.new(1, -16, 1, -48)
    scroll.BackgroundTransparency, scroll.ScrollBarThickness = 1, 8
    local y = 0
    local function text(value, height)
        local item = Instance.new("TextLabel", scroll)
        item.Position, item.Size = UDim2.fromOffset(8, y), UDim2.new(1, -24, 0, height or 28)
        item.BackgroundTransparency, item.TextColor3, item.TextSize = 1, Color3.new(1, 1, 1), 14
        item.TextWrapped, item.TextXAlignment, item.Text = true, Enum.TextXAlignment.Left, value
        y = y + (height or 28) + 6
        return item
    end
    local function entry(title, value)
        text(title)
        local item = Instance.new("TextBox", scroll)
        item.Position, item.Size = UDim2.fromOffset(8, y), UDim2.new(1, -24, 0, 32)
        item.Text, item.ClearTextOnFocus, item.TextSize = tostring(value or ""), false, 14
        item.BackgroundColor3, item.TextColor3 = Color3.fromRGB(40, 48, 62), Color3.new(1, 1, 1)
        y = y + 38
        return item
    end
    local function action(title, callback)
        local item = Instance.new("TextButton", scroll)
        item.Position, item.Size = UDim2.fromOffset(8, y), UDim2.new(1, -24, 0, 34)
        item.Text, item.TextSize = title, 14
        item.BackgroundColor3, item.TextColor3 = Color3.fromRGB(44, 65, 87), Color3.new(1, 1, 1)
        connections[#connections + 1] = item.Activated:Connect(function() callback(item) end)
        y = y + 40
        return item
    end
    features.dashboard = text("Collecting session metrics...", 150)
    action("Profile: " .. session.options.profile, function(item)
        local next_profile = {Aggressive = "Balanced", Balanced = "Conservative", Conservative = "Aggressive"}
        session.options.profile = next_profile[session.options.profile] or "Balanced"
        features.profile = session.options.profile
        item.Text = "Profile: " .. features.profile
        save_state()
    end)
    action("Auto replay / recovery: " .. tostring(session.options.auto_replay), function(item)
        session.options.auto_replay = not session.options.auto_replay
        item.Text = "Auto replay / recovery: " .. tostring(session.options.auto_replay)
        save_state()
    end)
    action("Retry blocked recovery", function()
        if features.outcome then
            features.outcome.attempts, features.outcome.last_attempt, features.outcome.fallback_attempted = 0, nil, nil
            features.recovery = "Recovery retry enabled"
        end
    end)
    text("Goals: 0 disables a numeric goal. Time counts active automation minutes.", 40)
    local level_goal = entry("Stop at level", session.options.level_goal)
    local clear_goal = entry("Stop after session clears", session.options.clear_goal)
    local minute_goal = entry("Stop after active minutes", session.options.minute_goal)
    local drop_goal = entry("Stop on a NEW drop with this exact item name; blank disables", session.options.drop_goal)
    features.goal_inputs = {level_goal = level_goal, clear_goal = clear_goal, minute_goal = minute_goal, drop_goal = drop_goal}
    action("Save goals", function()
        for key, input in pairs({level_goal = level_goal, clear_goal = clear_goal, minute_goal = minute_goal}) do
            session.options[key] = math.clamp(math.floor(tonumber(input.Text) or 0), 0, 999999)
        end
        session.options.drop_goal = drop_goal.Text:match("^%s*(.-)%s*$")
        save_state()
        features.recovery = "Goals saved"
    end)
    text("Ability overrides follow the equipped tool name when you change slots.", 40)
    local slot = "q"
    action("Edit active slot: Q", function(item) slot = slot == "q" and "e" or "q"; item.Text = "Edit active slot: " .. slot:upper() end)
    local range = entry("Ability range in studs; 0 uses automatic range", 0)
    local priority = entry("Priority adjustment (-5 to 5)", 0)
    local duration = entry("Buff duration in seconds; 0 leaves automatic behavior", 0)
    action("Save profile for currently equipped ability", function()
        local containers = {player:FindFirstChildOfClass("Backpack"), player.Character}
        for _, container in pairs(containers) do
            if container then
                for _, tool in ipairs(container:GetChildren()) do
                    local value = tool:FindFirstChild("abilitySlot")
                    if tool:IsA("Tool") and value and value.Value == slot then
                        session.options.abilities[tool.Name] = {range = math.clamp(tonumber(range.Text) or 0, 0, 150),
                            priority = math.clamp(tonumber(priority.Text) or 0, -5, 5),
                            buff_duration = math.clamp(tonumber(duration.Text) or 0, 0, 300)}
                        save_state(); features.recovery = "Ability profile saved: " .. tool.Name
                        return
                    end
                end
            end
        end
        features.recovery = "No ability found in slot " .. slot:upper()
    end)
    action("Auto-equip Warrior gear: " .. tostring(session.options.auto_equip), function(item)
        session.options.auto_equip = not session.options.auto_equip
        item.Text = "Auto-equip Warrior gear: " .. tostring(session.options.auto_equip)
        features.inventory_due = true; save_state()
    end)
    action("Retry stat spending", function() if features.retry_stats then features.retry_stats() end end)
    text("Selling protects equipped gear, locks, highest-power gear, Legendary and Ultimate items. Selling starts off.", 54)
    local locks = entry("Locks: comma-separated exact item names, UniqueItemIDs or kind:number", table.concat(session.options.locks, ", "))
    local rarity_names = {}
    for rarity, allowed in pairs(session.options.sell_rarities) do if allowed then rarity_names[#rarity_names + 1] = rarity end end
    local rarities = entry("Sell these rarities: common, uncommon, rare, epic", table.concat(rarity_names, ", "))
    action("Save equipment locks and selling rules", function()
        session.options.locks, session.options.sell_rarities = {}, {}
        for value in locks.Text:gmatch("[^,]+") do
            local clean = value:match("^%s*(.-)%s*$")
            if clean ~= "" then session.options.locks[#session.options.locks + 1] = clean end
        end
        for value in rarities.Text:lower():gmatch("[^,]+") do
            local clean = value:match("^%s*(.-)%s*$")
            if ({common = true, uncommon = true, rare = true, epic = true})[clean] then session.options.sell_rarities[clean] = true end
        end
        features.inventory_due = true; save_state()
    end)
    features.sell_button = action("Automatic selling: " .. tostring(session.options.auto_sell), function(item)
        session.options.auto_sell = not session.options.auto_sell
        item.Text = "Automatic selling: " .. tostring(session.options.auto_sell)
        features.inventory_due = true; save_state()
    end)
    action("Sell unequipped abilities: " .. tostring(session.options.sell_abilities == true), function(item)
        session.options.sell_abilities = not session.options.sell_abilities
        item.Text = "Sell unequipped abilities: " .. tostring(session.options.sell_abilities)
        save_state()
    end)
    scroll.CanvasSize = UDim2.fromOffset(0, y + 12)
    features.toggle_settings = function() panel.Visible = not panel.Visible end
end
features.build_settings()
function features.safe_part()
    local zone = features.safe_zone
    if zone and zone.part.Parent and os.clock() < zone.expires then return zone.part end
    features.safe_zone = nil
end
function features.navigation_target()
    local safe = features.safe_part()
    if safe then return safe, safe end
    return target and enemy_root(target), target
end
function features.indicator(part)
    if not part:IsA("BasePart") or part.Name ~= "precast" then return end
    local top = part
    while top.Parent and top.Parent ~= workspace do top = top.Parent end
    local templates = RS:FindFirstChild("enemyProjectiles")
    if top.Parent == workspace and templates and templates:FindFirstChild(top.Name) then features.indicators[part] = true end
end
for _, part in ipairs(workspace:GetDescendants()) do features.indicator(part) end
connections[#connections + 1] = workspace.DescendantAdded:Connect(function(part) features.indicator(part) end)
function features.signal(remote, kind, payload)
    if not session.enabled then return end
    if remote == "bossSpecficEvents" and kind == "Second Boss Show Safe Spot" and typeof(payload) == "Instance" then
        local part = payload:FindFirstChild("hitBox")
        if part and part:IsA("BasePart") then features.safe_zone = {part = part, expires = os.clock() + 6.6} end
    elseif remote == "volcanicBossSpecficEvents" and kind == "First Boss Sky Shot" and typeof(payload) == "Vector3" then
        local projectiles = RS:FindFirstChild("enemyProjectiles")
        local template = projectiles and projectiles:FindFirstChild("firstBossSkyShot")
        local precast = template and template:FindFirstChild("precast")
        if template and template:IsA("Model") and template.PrimaryPart and precast and precast:IsA("BasePart") then
            local frame = CFrame.new(payload) * template.PrimaryPart.CFrame:ToObjectSpace(precast.CFrame)
            features.hazards[#features.hazards + 1] = {frame = frame, size = precast.Size, expires = os.clock() + 3.5}
        end
    elseif remote == "bossSpecficEvents" and kind == "Minion Explosion" and typeof(payload) == "CFrame" then
        features.hazards[#features.hazards + 1] = {frame = payload, size = Vector3.new(40, 40, 40), expires = os.clock() + 0.5}
    end
    if #features.hazards > 64 then table.remove(features.hazards, 1) end
end
function features.hazard_risk(position, now)
    local risk = 0
    local function rectangle(frame, size)
        local local_point = frame:PointToObjectSpace(position)
        local x = math.abs(local_point.X) / (size.X / 2 + 3)
        local z = math.abs(local_point.Z) / (size.Z / 2 + 3)
        if math.abs(local_point.Y) < math.max(15, size.Y / 2 + 5) and x < 1 and z < 1 then
            risk = math.max(risk, 1 - math.max(x, z)^2 * 0.4)
        end
    end
    for _, hazard in ipairs(features.hazards) do
        if now <= hazard.expires then rectangle(hazard.frame, hazard.size) end
    end
    for part in pairs(features.indicators) do
        if part.Parent and part.Transparency < 0.95 then rectangle(part.CFrame, part.Size) end
    end
    return risk
end
task.spawn(function()
    local previous_tick, last_save, previous_started = os.clock(), 0, false
    local previous_xp, xp_name
    while session.alive do
        local ok, err = pcall(function()
            local now = os.clock()
            if session.enabled then session.metrics.active_seconds = session.metrics.active_seconds + math.min(now - previous_tick, 2) end
            previous_tick = now
            local goal = Policy.goal(session.options, session.metrics, features.level())
            if session.enabled and goal then features.set_enabled(false, goal) end
            local started = workspace:FindFirstChild("dungeonStarted")
            if started and started.Value == true and not previous_started then
                if features.outcome then
                    session.metrics.round = session.metrics.round + 1
                    features.outcome = nil
                end
                features.run_started = os.time()
            end
            previous_started = started and started.Value == true or false
            local character = player.Character
            local humanoid = character and character:FindFirstChildOfClass("Humanoid")
            if humanoid and features.death_watch ~= humanoid then
                features.death_watch = humanoid
                connections[#connections + 1] = humanoid.Died:Connect(function()
                    if session.enabled then session.metrics.deaths = session.metrics.deaths + 1; save_state() end
                end)
            end
            if session.enabled and not features.outcome then
                local _, actor, root = character_parts()
                if root and actor.WalkSpeed > 0 and not root.Anchored and steering.Magnitude > 0.5 then
                    local progress = features.last_progress and flat(root.Position - features.last_progress).Magnitude or 10
                    features.stuck_seconds = progress < 0.6 and features.stuck_seconds + 1 or 0
                    if features.stuck_seconds >= 2 then
                        waypoints, path_target, last_path = nil, nil, 0
                        session.metrics.recoveries = session.metrics.recoveries + 1
                        if now - features.last_jump > 3 and actor.FloorMaterial ~= Enum.Material.Air then
                            actor.Jump, features.last_jump = true, now
                        end
                        if features.stuck_seconds >= 6 and target then
                            features.blocked_targets[target] = now + 5
                            target, features.stuck_seconds = nil, 0
                        end
                    end
                    features.last_progress = root.Position
                else features.last_progress, features.stuck_seconds = nil, 0 end
            end
            local indicators = 0
            for part in pairs(features.indicators) do
                if not part.Parent then features.indicators[part] = nil
                elseif part.Transparency < 0.95 then indicators = indicators + 1 end
            end
            for index = #features.hazards, 1, -1 do
                if now > features.hazards[index].expires then table.remove(features.hazards, index) end
            end
            features.telegraphs = "Enemy indicators: " .. indicators .. "; signal areas: " .. #features.hazards
                .. (features.safe_part() and "; moving to safe zone" or "")
            local stats = player:FindFirstChild("leaderstats")
            local counter = player:FindFirstChild("totalXP") or player:FindFirstChild("experience")
                or (stats and (stats:FindFirstChild("XP") or stats:FindFirstChild("Experience")))
            if counter and (counter:IsA("IntValue") or counter:IsA("NumberValue")) then
                if previous_xp and xp_name == counter.Name and counter.Value >= previous_xp then
                    session.metrics.observed_xp = session.metrics.observed_xp + counter.Value - previous_xp
                end
                previous_xp, xp_name = counter.Value, counter.Name
                features.xp_available = true
            end
            features.recover()
            if now - last_save >= 5 then save_state(); last_save = now end
            if features.sell_button then features.sell_button.Text = "Automatic selling: " .. tostring(session.options.auto_sell) end
            if features.dashboard then
                local m = session.metrics
                local average = m.clears > 0 and string.format("%.0fs", m.clear_seconds / m.clears) or "--"
                features.dashboard.Text = string.format("Clears %d | Failures %d | Deaths %d | Avg %s\nActive %.1f min | Casts %d | Failed casts %d | Recoveries %d\nObserved XP: %s\n%s\n%s\n%s\n%s",
                    m.clears, m.failures, m.deaths, average, m.active_seconds / 60, m.cast_started, m.cast_failed, m.recoveries,
                    features.xp_available and tostring(m.observed_xp) or "counter unavailable", features.recovery, features.inventory, features.telegraphs,
                    features.boss_summary or "Attack observations pending")
            end
        end)
        if not ok then features.recovery = "Session monitor: " .. tostring(err) end
        task.wait(1)
    end
end)

local function begin_attack(model, id, length, track)
    if not session.enabled then return end
    local part = enemy_root(model)
    if not part then return end
    local key = tostring(game.GameId) .. "/" .. model.Name .. "/" .. id
    local boss_gui = player.PlayerGui:FindFirstChild("bossHealth")
    local boss_name = boss_gui and boss_gui:FindFirstChild("bossName", true)
    local humanoid = model:FindFirstChildOfClass("Humanoid")
    if boss_gui and boss_gui.Enabled and boss_name and boss_name.Text == model.Name and humanoid and humanoid.MaxHealth > 0 then
        local health = humanoid.Health / humanoid.MaxHealth
        key = key .. (health > 0.65 and "/high" or (health > 0.3 and "/middle" or "/low"))
    end
    local started = os.clock() - (track and math.clamp(track.TimePosition, 0, 6) or 0)
    for _, attack in ipairs(active_attacks) do
        if attack.model == model and attack.key == key and math.abs(attack.started - started) < 0.15 then return end
    end
    local record = session.metrics.boss_records[model.Name]
    if type(record) ~= "table" then record = {}; session.metrics.boss_records[model.Name] = record end
    for _, name in ipairs({"signals", "hits", "predictions", "unhurt"}) do record[name] = tonumber(record[name]) or 0 end
    record.signals = record.signals + 1
    active_attacks[#active_attacks + 1] = {
        model = model, key = key, started = started, origin = part.CFrame,
        duration = math.clamp(length and length > 0 and length or 2, 0.5, 6), track = track, record = record,
    }
    if #active_attacks > 64 then table.remove(active_attacks, 1) end
end
local function watch_rigs()
    local present = {}
    for _, model in ipairs(enemies) do
        present[model] = true
        if not watched_rigs[model] then
            local animator = model:FindFirstChildWhichIsA("Animator", true)
            if animator then
                local function observe_track(track)
                    local priority = tostring(track.Priority)
                    if priority:find("Action", 1, true) and track.Animation then
                        begin_attack(model, track.Animation.AnimationId, track.Length, track)
                    end
                end
                watched_rigs[model] = animator.AnimationPlayed:Connect(observe_track)
                for _, track in ipairs(animator:GetPlayingAnimationTracks()) do observe_track(track) end
            end
        end
    end
    for model, connection in pairs(watched_rigs) do
        if not present[model] then connection:Disconnect(); watched_rigs[model] = nil end
    end
    for index = #active_attacks, 1, -1 do
        local attack = active_attacks[index]
        if not enemy_root(attack.model) or os.clock() - attack.started > attack.duration + 1 then
            if attack.predicted and not attack.hit and not attack.uncertain and attack.record then
                attack.record.unhurt = attack.record.unhurt + 1
            end
            table.remove(active_attacks, index)
        elseif not attack.predicted then
            local _, _, root = character_parts()
            local part = enemy_root(attack.model)
            local pattern = learned.patterns[attack.key]
            if root and part and Policy.window(pattern, os.clock() - attack.started + 0.35) then
                local point = part.CFrame:PointToObjectSpace(root.Position)
                for _, sample in ipairs(pattern.samples) do
                    if (point.X - sample.x)^2 + (point.Z - sample.z)^2 < 14 then
                        attack.predicted = true
                        if attack.record then attack.record.predictions = attack.record.predictions + 1 end
                        break
                    end
                end
            end
        end
    end
end
local function pattern_risk(position, now)
    local risk = features and features.hazard_risk and features.hazard_risk(position, now) or 0
    for _, attack in ipairs(active_attacks) do
        local part = enemy_root(attack.model)
        if part then
            local elapsed = now - attack.started
            local pattern = learned.patterns[attack.key]
            if Policy.window(pattern, elapsed) then
                local current = part.CFrame:PointToObjectSpace(position)
                local original = attack.origin:PointToObjectSpace(position)
                for _, sample in ipairs(pattern.samples) do
                    local current_gap = (current.X - sample.x)^2 + (current.Z - sample.z)^2
                    local original_gap = (original.X - sample.x)^2 + (original.Z - sample.z)^2
                    local gap = math.min(current_gap, original_gap)
                    if gap < 36 then risk = math.max(risk, 1 - gap / 36) end
                end
            elseif not pattern or (pattern.count or 0) < 3 then
                local offset = flat(position - part.Position)
                local facing = flat(part.CFrame.LookVector)
                if elapsed > 0.15 and elapsed < math.min(attack.duration, 1.4)
                    and offset.Magnitude < 14 and offset.Magnitude > 0.01
                    and facing.Magnitude > 0.01 and facing.Unit:Dot(offset.Unit) > 0.35 then
                    risk = math.max(risk, 0.7)
                end
            end
        end
    end
    return risk
end
local health_connection, health_humanoid
local function watch_health()
    local _, humanoid = character_parts()
    if humanoid == health_humanoid then return end
    if health_connection then health_connection:Disconnect() end
    health_humanoid = humanoid
    if not humanoid then return end
    local previous = humanoid.Health
    health_connection = humanoid.HealthChanged:Connect(function(health)
        local damaged = health < previous
        previous = health
        if not damaged or not session.enabled then return end
        local character = humanoid.Parent
        local root = character and character:FindFirstChild("HumanoidRootPart")
        if not root then return end
        for _, attack in ipairs(active_attacks) do attack.uncertain = true end
        local candidates, nearby = {}, 0
        for _, model in ipairs(enemies) do
            local part = enemy_root(model)
            if part and (part.Position - root.Position).Magnitude < 25 then nearby = nearby + 1 end
        end
        -- Damage in a crowd has an ambiguous source; do not train on it.
        if nearby > 1 then return end
        for _, attack in ipairs(active_attacks) do
            local elapsed = os.clock() - attack.started
            local part = enemy_root(attack.model)
            if part and elapsed >= 0.1 and elapsed <= 4
                and (part.Position - root.Position).Magnitude < 80 then
                candidates[#candidates + 1] = attack
            end
        end
        -- Prefer a single animation signal over a duplicate boss event.
        local animations = {}
        for _, attack in ipairs(candidates) do if attack.track then animations[#animations + 1] = attack end end
        if #animations > 0 then candidates = animations end
        if #candidates ~= 1 then return end
        local attack = candidates[1]
        if attack.sampled then return end
        attack.hit, attack.uncertain = true, false
        if attack.record then attack.record.hits = attack.record.hits + 1 end
        attack.sampled = true
        local part = enemy_root(attack.model)
        local point = part.CFrame:PointToObjectSpace(root.Position)
        local pattern = learned.patterns[attack.key] or {}
        Policy.observe(pattern, os.clock() - attack.started, point.X, point.Z)
        learned.patterns[attack.key] = pattern
        dirty_patterns = true
    end)
end
connections[#connections + 1] = player.CharacterRemoving:Connect(function()
    if health_connection then health_connection:Disconnect(); health_connection = nil end
    health_humanoid = nil
end)
for _, remote in ipairs(remotes:GetChildren()) do
    local name = remote.Name:lower()
    if remote:IsA("RemoteEvent") and (name:find("specficevents", 1, true)
        or name:find("specificevents", 1, true) or name:find("clientevents", 1, true)) then
        connections[#connections + 1] = remote.OnClientEvent:Connect(function(kind, payload)
            features.signal(remote.Name, kind, payload)
            if #enemies == 1 and target then
                local id = (type(kind) == "string" or type(kind) == "number") and tostring(kind) or "signal"
                begin_attack(target, remote.Name .. "/" .. id, 3)
            end
        end)
    end
end
task.spawn(function()
    local last_save = 0
    while session.alive do
        local ok, err = pcall(function()
            watch_health()
            watch_rigs()
            local learned_count, tentative = 0, 0
            for _, pattern in pairs(learned.patterns) do
                if (pattern.count or 0) >= 3 then learned_count = learned_count + 1 else tentative = tentative + 1 end
            end
            learning_note = "Patterns: " .. learned_count .. " learned / " .. tentative .. " tentative; signals " .. #active_attacks
            local record = target and session.metrics.boss_records[target.Name]
            if record then
                features.boss_summary = string.format("%s: %d signals, %d associated hit windows; %d predictions, %d unhurt windows",
                    target.Name, record.signals, record.hits, record.predictions, record.unhurt)
            end
            if os.clock() - last_save >= 15 then save_patterns(); last_save = os.clock() end
        end)
        if not ok then learning_note = "Pattern error: " .. tostring(err) end
        task.wait(0.5)
    end
    if health_connection then health_connection:Disconnect() end
end)

local function ability_candidates(character, now)
    local backpack = player:FindFirstChildOfClass("Backpack")
    local tools = backpack and backpack:GetChildren() or {}
    for _, tool in ipairs(character:GetChildren()) do tools[#tools + 1] = tool end
    local skills = {}
    for _, tool in ipairs(tools) do
        local slot = tool:FindFirstChild("abilitySlot")
        local cooldown = tool:FindFirstChild("cooldown")
        local event = tool:FindFirstChild("localEvent")
        if tool:IsA("Tool") and slot and (slot.Value == "q" or slot.Value == "e")
            and cooldown and event and event:IsA("BindableEvent") then
            local function number(name, fallback)
                local value = tool:FindFirstChild(name)
                if value and (value:IsA("NumberValue") or value:IsA("IntValue")) then return value.Value end
                return fallback
            end
            local previous = attempts[tool] or {next_ready = 0, last_used = now - 30}
            local profile = session.options.abilities[tool.Name]
            if type(profile) ~= "table" then profile = {} end
            local duration = math.clamp(tonumber(profile.buff_duration) or 0, 0, 300)
            local override_range = math.clamp(tonumber(profile.range) or 0, 0, 150)
            local buff = duration > 0 or Policy.is_buff(tool.Name, tool:FindFirstChild("buffPower") ~= nil)
            skills[#skills + 1] = {tool = tool, slot = slot.Value, event = event,
                cooldown = cooldown.Value, length = number("cooldownLength", 1),
                damage = number("damage", 1), buff = buff, buff_duration = duration,
                priority = math.clamp(tonumber(profile.priority) or 0, -5, 5),
                range = override_range > 0 and override_range or (buff and (config.attack_range + 6) or number("range", tool:FindFirstChild("fireballShootEvent") and 60 or 12)),
                next_ready = previous.next_ready, last_used = previous.last_used}
        end
    end
    return skills
end

local function body_radius(part)
    return part.Size and math.clamp(math.max(part.Size.X, part.Size.Z) / 2, 1, 8) or 1
end
local function tactical_direction(root, part, params, now)
    local desired = config.spacing + body_radius(part) - 1
    local stance = session.options and session.options.profile or "Balanced"
    desired = desired + (stance == "Conservative" and 3 or (stance == "Aggressive" and -1 or 0))
    if controlled and controlled.MaxHealth and controlled.MaxHealth > 0
        and controlled.Health / controlled.MaxHealth < (stance == "Conservative" and 0.5 or 0.35) then desired = desired + 5 end
    local step = math.clamp((controlled and controlled.WalkSpeed or 16) * 0.35, 3, 6)
    local origin = root.Position + Vector3.new(0, 3, 0)
    local down = Vector3.new(0, -30, 0)
    local current_floor = workspace:Raycast(origin, down, params)
    local best, best_score, moving_choices = nil, nil, 0
    for index = 0, 12 do
        local angle = index * math.pi / 6
        local direction = index == 12 and Vector3.zero or Vector3.new(math.cos(angle), 0, math.sin(angle))
        local position = root.Position + direction * step
        local valid = direction.Magnitude < 0.01
            or (not workspace:Raycast(root.Position, direction * step, params)
            and (not current_floor or workspace:Raycast(origin + direction * step, down, params)))
        if valid then
            if direction.Magnitude > 0.01 then moving_choices = moving_choices + 1 end
            local score = -math.abs(flat(position - part.Position).Magnitude - desired) * 0.7
            score = score - pattern_risk(position, now + 0.35) * 80
            for _, model in ipairs(enemies) do
                local enemy = enemy_root(model)
                if enemy then
                    local velocity = enemy.AssemblyLinearVelocity or Vector3.zero
                    if velocity.Magnitude > 40 then velocity = velocity.Unit * 40 end
                    local future = enemy.Position + flat(velocity) * 0.25
                    local offset = flat(position - future)
                    local gap = offset.Magnitude - body_radius(enemy)
                    if gap < 5 then score = score - (5 - gap)^2 * 5 end
                    local facing = flat(enemy.CFrame.LookVector)
                    if gap < 13 and offset.Magnitude > 0.01 and facing.Magnitude > 0.01 then
                        local front = facing.Unit:Dot(offset.Unit)
                        if front > 0.25 then score = score - (13 - gap) * (front - 0.25) end
                    end
                end
            end
            score = score + steering:Dot(direction) * 0.3
            if index == 12 then score = score + 0.15 end
            if not best_score or score > best_score then best, best_score = direction, score end
        end
    end
    local reason = pattern_risk(root.Position, now + 0.35) >= 0.8 and "Avoiding learned attack"
        or (best and best.Magnitude < 0.01 and "Holding safe spacing" or "Seeking safer spacing")
    if moving_choices == 0 then reason = "No safe movement direction: walls / ledges" end
    return best or Vector3.zero, reason
end

local stat_arguments, stats_failed
-- Verified from the supplied Ui.inventory handler: stat key and amount.
stat_arguments = {"physicalPower", 1, n = 2}
stat_note = "Stats: physicalPower handler available"
features.retry_stats = function() stats_failed = nil; stat_note = "Stats: retry enabled" end
local function point_count()
    local exact = player.FindFirstChild and player:FindFirstChild("skillPoints")
    if exact and (exact:IsA("IntValue") or exact:IsA("NumberValue")) then return exact.Value end
    local best, rank, ambiguous
    local function consider(name, value)
        local priority = Policy.point_rank(name)
        if priority and type(value) == "number" and value >= 0 and value < 1000000 then
            if not rank or priority > rank then best, rank, ambiguous = value, priority, false
            elseif priority == rank and value ~= best then ambiguous = true end
        end
    end
    for name, value in pairs(player:GetAttributes()) do
        consider(name, value)
    end
    local gui = player:FindFirstChildOfClass("PlayerGui")
    local backpack = player:FindFirstChildOfClass("Backpack")
    for _, node in ipairs(player:GetDescendants()) do
        local name = node.Name:lower():gsub("%W", "")
        if Policy.point_rank(name) and (node:IsA("IntValue") or node:IsA("NumberValue"))
            and not (gui and node:IsDescendantOf(gui))
            and not (backpack and node:IsDescendantOf(backpack)) then consider(name, node.Value) end
    end
    if rank and rank >= 90 then return not ambiguous and best or nil end
    local inventory = gui and gui:FindFirstChild("inventory")
    if inventory then
        for _, node in ipairs(inventory:GetDescendants()) do
            if node:IsA("TextLabel") then
                local name = node.Name:lower():gsub("%W", "")
                local text = node.Text:gsub(",", "")
                local lower = text:lower()
                if Policy.point_rank(name) or lower:find("skill points", 1, true)
                    or lower:find("stat points", 1, true) or lower:find("unspent points", 1, true)
                    or lower:find("available points", 1, true) then
                    local count = text:match("[Pp]oints%s*:%s*(%d+)")
                        or text:match("(%d+)%s+[Ss]kill%s+[Pp]oints")
                        or text:match("^%s*(%d+)%s*$")
                    if count then consider(Policy.point_rank(name) and name or "skillpoints", tonumber(count)) end
                end
            end
        end
    end
    return not ambiguous and best or nil
end
task.spawn(function()
    if type(decompile) ~= "function" then stat_note = "Stats: decompiler unavailable"; return end
    local seen = setmetatable({}, {__mode = "k"})
    local failures = setmetatable({}, {__mode = "k"})
    while session.alive and (not session.calls.replayDungeon or not session.calls.ReturnToLobbyEvent) do
        local candidates = {}
        for _, root in ipairs({player:WaitForChild("PlayerGui"), player:WaitForChild("PlayerScripts"), RS, game:GetService("ReplicatedFirst")}) do
            for _, script in ipairs(root:GetDescendants()) do
                if not session.alive then return end
                if not seen[script] and (script:IsA("ModuleScript") or script:IsA("LocalScript")) then
                    local path = script:GetFullName():lower()
                    local priority = (path:find("inventory", 1, true) or path:find("stat", 1, true)
                        or path:find("point", 1, true)) and 0 or 1
                    candidates[#candidates + 1] = {script = script, path = path, priority = priority}
                end
            end
        end
        table.sort(candidates, function(a, b)
            if a.priority ~= b.priority then return a.priority < b.priority end
            return a.path < b.path
        end)
        for _, candidate in ipairs(candidates) do
            if not session.alive then return end
            local script = candidate.script
            local ok, source = pcall(decompile, script)
            if ok and type(source) == "string" then
                seen[script] = true
                for name in pairs(Policy.zero_argument_calls(source)) do session.calls[name] = true end
                if not stat_arguments and source:find("spendSkillPoint", 1, true) then
                    stat_arguments = Policy.stat_arguments(source)
                    if stat_arguments then stat_note = "Stats: physical handler found in client" end
                end
            else
                failures[script] = (failures[script] or 0) + 1
                if failures[script] >= 2 then seen[script] = true end
            end
            task.wait()
        end
        task.wait(10)
    end
end)
task.spawn(function()
    while session.alive do
        if session.enabled and stat_arguments and not stats_failed then
            local ok, err = pcall(function()
                local before = point_count()
                if before == nil then stat_note = "Stats: point counter not found"; return end
                if before <= 0 then stat_note = "Stats: no unspent points"; return end
                local remote = remotes:FindFirstChild("spendSkillPoint")
                assert(remote and remote:IsA("RemoteEvent"), "spendSkillPoint unavailable")
                local amount = math.max(1, math.min(math.floor(before), 10))
                remote:FireServer("physicalPower", amount)
                local deadline = os.clock() + 2
                while os.clock() < deadline and session.alive and session.enabled do
                    local after = point_count()
                    if after and after < before then
                        stat_note = "Stats: physical point confirmed; " .. after .. " left"
                        return
                    end
                    task.wait(0.1)
                end
                if not session.alive or not session.enabled then return end
                stats_failed = true
                stat_note = "Stats: server update unconfirmed; stopped retrying"
            end)
            if not ok then stats_failed = true; stat_note = "Stats error: " .. tostring(err) end
        end
        task.wait(0.5)
    end
end)

task.spawn(function()
    while session.alive do
        if session.enabled and not lobby_place then
            local ok, err = pcall(refresh_enemies)
            if not ok then note = "Enemy scan error: " .. tostring(err) end
        end
        task.wait(0.5)
    end
end)

task.spawn(function()
    while session.alive do
        if session.enabled then
            local ok, err = pcall(function()
                local character, humanoid, root = character_parts()
                if lobby_place then note = lobby_note ~= "" and lobby_note or "Preparing lobby"; return end
                if features.outcome then note = features.recovery; return end
                if not character then note = "Waiting for character"; return end
                local peaceful = player:FindFirstChild("peaceful")
                if peaceful and peaceful.Value then note = "Waiting for dungeon"; return end
                target = find_target(root)
                local part = target and enemy_root(target)
                if not part then
                    note = "Detected 0 live enemies. If visible, click Copy enemy details."
                    ability_note = "Abilities: waiting for target"
                    return
                end
                local distance = math.max(0, (part.Position - root.Position).Magnitude - body_radius(part) + 1)
                note = "Detected " .. #enemies .. " | " .. target.Name .. " | " .. math.floor(distance) .. " studs"
                if distance > config.cast_range then return end
                local busy = character:FindFirstChild("busyCasting")
                if not busy or busy.Value then ability_note = "Abilities: cast animation active"; return end
                if pending_cast then ability_note = "Abilities: waiting for cast start"; return end
                local now = os.clock()
                local danger = pattern_risk(root.Position, now + 0.25)
                local safe = features.safe_part()
                if safe and flat(root.Position - safe.Position).Magnitude > math.max(1, math.min(safe.Size.X, safe.Size.Z) / 2 - 2) then danger = 1 end
                local stance = session.options.profile
                local danger_limit = stance == "Conservative" and 0.4 or (stance == "Aggressive" and 0.8 or 0.6)
                local skill = Policy.choose(ability_candidates(character, now), now, distance, danger, danger_limit)
                if skill then
                    local offset = flat(part.Position - root.Position)
                    local facing = flat(root.CFrame.LookVector)
                    if not skill.buff and offset.Magnitude > 0.01 and facing.Magnitude > 0.01
                        and facing.Unit:Dot(offset.Unit) < 0.85 then
                        ability_note = "Abilities: aligning with target"
                        return
                    end
                    local attempt = {next_ready = now + 0.5, last_used = skill.last_used}
                    attempts[skill.tool] = attempt
                    pending_cast = attempt
                    local sent, cast_error = pcall(function()
                        skill.event:Fire()
                        remotes.abilityUsed:FireServer(skill.slot, skill.tool)
                    end)
                    if not sent then pending_cast = nil; error(cast_error) end
                    ability_note = "Requested " .. skill.slot:upper() .. ": " .. skill.tool.Name
                    task.spawn(function()
                        local deadline = os.clock() + 0.35
                        local started = false
                        repeat
                            if not session.alive or not session.enabled or player.Character ~= character then break end
                            local cooldown = skill.tool:FindFirstChild("cooldown")
                            if busy.Value or (cooldown and cooldown.Value > 0) then started = true; break end
                            task.wait(0.025)
                        until os.clock() >= deadline
                        if started then
                            attempt.next_ready = now + math.max(skill.length, skill.buff_duration or 0, 0.4)
                            attempt.last_used = now
                            session.metrics.cast_started = session.metrics.cast_started + 1
                        else
                            attempt.next_ready = os.clock() + 0.4
                            session.metrics.cast_failed = session.metrics.cast_failed + 1
                        end
                        if pending_cast == attempt then pending_cast = nil end
                    end)
                    return
                end
                ability_note = danger >= danger_limit and "Abilities: evading attack window" or "Abilities: waiting for cooldown / range"
                if danger >= danger_limit then return end
                if distance <= config.attack_range and os.clock() - last_swing >= 0.6 then
                    for _, item in ipairs(character:GetChildren()) do
                        if item:IsA("Accessory") and item:FindFirstChild("Weapon") then
                            local event = item:FindFirstChildOfClass("RemoteEvent")
                            if event then
                                last_swing = os.clock()
                                event:FireServer()
                                remotes.weaponUsed:FireServer()
                                break
                            end
                        end
                    end
                end
            end)
            if not ok then note = "Combat error: " .. tostring(err) end
        end
        if session.alive then
            status.Text = session.exporting and "Exporting client controls..."
                or (note .. (lobby_place and "" or ("\n" .. movement_note .. "\n" .. ability_note))
                .. "\n" .. learning_note .. "\n" .. stat_note)
        end
        task.wait(0.05)
    end
end)

-- Compute routes separately; the frame controller keeps following the previous route.
task.spawn(function()
    while session.alive do
        if session.enabled and not features.outcome then
            local ok, err = pcall(function()
                local character, _, root = character_parts()
                local part, model = features.navigation_target()
                local peaceful = player:FindFirstChild("peaceful")
                if not root or not part or (peaceful and peaceful.Value) then return end
                local params = ray_params(character)
                if (part.Position - root.Position).Magnitude < 18
                    and clear_path(root, part.Position, params) then return end
                local now = os.clock()
                local changed = model ~= path_target
                local moved = not path_goal or (part.Position - path_goal).Magnitude > 6
                if now - progress_time >= 1 then
                    stalled = path_origin ~= nil and (root.Position - path_origin).Magnitude < 1
                    path_origin, progress_time = root.Position, now
                end
                local stuck = stalled
                local exhausted = not waypoints or not waypoints[waypoint_index]
                if now - last_path >= 1 and (changed or moved or stuck or exhausted) then
                    last_path = now
                    local goal = part.Position
                    local path = Paths:CreatePath({AgentRadius = 2, AgentHeight = 5, AgentCanJump = true})
                    path_note = "Computing route"
                    path:ComputeAsync(root.Position, goal)
                    local _, navigation_key = features.navigation_target()
                    if not session.alive or not session.enabled or navigation_key ~= model then return end
                    if path.Status == Enum.PathStatus.Success then
                        waypoints, waypoint_index, path_target = path:GetWaypoints(), 2, model
                        path_goal = goal
                        path_note = "Route ready"
                    else
                        path_note = "Route result: " .. tostring(path.Status)
                    end
                end
            end)
            if not ok then path_note = "Path error: " .. tostring(err) end
        end
        task.wait(0.25)
    end
end)

local planned = Vector3.zero
local decision_time = 0
-- Default player input calls Move() each frame; submit steering after it.
Run:BindToRenderStep(render_name, Enum.RenderPriority.Character.Value + 1, function(dt)
    if not session.alive then return end
    local ok, err = pcall(function()
        local character, humanoid, root = character_parts()
        local part, navigation_key = features.navigation_target()
        local peaceful = player:FindFirstChild("peaceful")
        if not session.enabled or features.outcome or not root or not part or (peaceful and peaceful.Value) then
            movement_note = not session.enabled and "Movement paused"
                or (not root and "Waiting for character"
                or ((peaceful and peaceful.Value) and "Movement waiting for dungeon" or "Waiting for target"))
            release_movement()
            return
        end
        if root.Anchored or humanoid.WalkSpeed <= 0 or humanoid.PlatformStand or humanoid.Sit then
            movement_note = root.Anchored and "Character root is anchored"
                or (humanoid.WalkSpeed <= 0 and "Character WalkSpeed is zero"
                or (humanoid.PlatformStand and "Character is in PlatformStand" or "Character is seated"))
            release_movement()
            return
        end
        if controlled ~= humanoid then
            release_movement()
            controlled, original_rotate = humanoid, humanoid.AutoRotate
        end
        humanoid.AutoRotate = false
        local delta = flat(part.Position - root.Position)
        if os.clock() >= decision_time then
            decision_time = os.clock() + 0.08
            local params = ray_params(character)
            local distance = delta.Magnitude
            local toward = distance > 0.01 and delta.Unit or Vector3.new(0, 0, -1)
            local direction = Vector3.zero
            local reason = path_note
            local safe = features.safe_part()
            if safe and distance <= math.max(1, math.min(safe.Size.X, safe.Size.Z) / 2 - 2) then
                direction, reason = Vector3.zero, "Inside boss safe zone"
            elseif safe and clear_path(root, safe.Position, params) then
                direction, reason = toward, "Moving to boss safe zone"
            elseif (distance < 24 or pattern_risk(root.Position, os.clock() + 0.35) >= 0.6)
                and clear_path(root, part.Position, params) then
                reason = "Approaching target"
                local radial = math.clamp((distance - config.spacing) / 4, -1, 1)
                direction = toward * radial
                if evasive then
                    direction, reason = tactical_direction(root, part, params, os.clock())
                end
            else
                if path_target == navigation_key and waypoints then
                    while waypoints[waypoint_index]
                        and flat(waypoints[waypoint_index].Position - root.Position).Magnitude < 3 do
                        waypoint_index = waypoint_index + 1
                    end
                    local waypoint = waypoints[waypoint_index]
                    if waypoint then
                        reason = "Following route"
                        direction = flat(waypoint.Position - root.Position)
                        if waypoint.Action == Enum.PathWaypointAction.Jump then humanoid.Jump = true end
                    end
                end
                if direction.Magnitude < 0.01 and clear_path(root, part.Position, params) then
                    direction = toward
                    reason = "Approaching target"
                end
            end
            if direction.Magnitude > 1 then direction = direction.Unit end
            if direction.Magnitude > 0.01 then
                local heading = direction.Unit
                local obstruction = workspace:Raycast(root.Position, heading * 3, params)
                if obstruction then
                    direction = direction - obstruction.Normal * direction:Dot(obstruction.Normal)
                    direction = flat(direction)
                    reason = "Wall: " .. obstruction.Instance.Name
                end
                if direction.Magnitude > 0.01 then
                    local origin = root.Position + Vector3.new(0, 3, 0)
                    local ahead = origin + direction.Unit * 4
                    local down = Vector3.new(0, -30, 0)
                    -- A missing ray hit everywhere is not evidence of a ledge.
                    local current_floor = workspace:Raycast(origin, down, params)
                    if current_floor and not workspace:Raycast(ahead, down, params) then
                        direction = Vector3.zero
                        reason = "Ledge ahead: waiting for route"
                    end
                end
            end
            planned = direction
            movement_note = reason
        end
        steering = steering:Lerp(planned, 1 - math.exp(-16 * dt))
        if steering.Magnitude > 1 then steering = steering.Unit end
        humanoid:Move(steering, false)
        local enemy = target and enemy_root(target)
        local face = enemy and flat(enemy.Position - root.Position) or (delta.Magnitude <= config.cast_range and delta or steering)
        if face.Magnitude > 0.01 then
            local aim = CFrame.lookAt(root.Position, root.Position + face)
            root.CFrame = root.CFrame:Lerp(aim, 1 - math.exp(-18 * dt))
        end
    end)
    if not ok then release_movement(); movement_note = "Movement error: " .. tostring(err) end
end)
]==]
local run, err = loadstring(source)
assert(run, err)
run(source)
