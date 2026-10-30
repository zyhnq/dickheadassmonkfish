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
-- Mirrors the supplied native blacksmith's calculateUpgradeCost.
function Policy.upgrade_cost(current)
    current = math.max(0, math.floor(tonumber(current) or 0))
    if current > 466 then return 100000 end
    local cost = 100
    for _ = 1, current do
        local next_cost = cost * 1.06 + 50
        cost = next_cost - cost > 220 and cost + 220 or next_cost
    end
    return math.floor(math.min(cost, 100000))
end
function Policy.upgrade_plan(items, gold, reserve, locks, selected, strategy)
    local available = math.max(0, (tonumber(gold) or 0) - (tonumber(reserve) or 0))
    local chosen, cheapest, best_value
    for _, item in ipairs(items) do
        local current, maximum = tonumber(item.record.currentUpgrade), tonumber(item.record.maxUpgrades)
        local selected_item = selected and item.kind == selected.kind and item.id == selected.id
            and (not selected.record.UniqueItemID or item.record.UniqueItemID == selected.record.UniqueItemID)
        if item.kind ~= "ability" and (item.equipped or selected_item) and not Policy.locked(item, locks)
            and current and maximum and current >= 0 and current % 1 == 0 and current < maximum then
            local cost = Policy.upgrade_cost(current)
            local value = strategy == "efficient" and Policy.upgrade_value(item, cost) or -cost
            if cost <= available and (not best_value or value > best_value or (value == best_value and item.kind == "weapon")) then
                chosen, cheapest, best_value = item, cost, value
            end
        end
    end
    if not chosen then return end
    local record, count, cost = chosen.record, 1, cheapest
    if record.maxUpgrades - record.currentUpgrade >= 10 then
        local total = 0
        for offset = 0, 9 do total = total + Policy.upgrade_cost(record.currentUpgrade + offset) end
        if total <= available then count, cost = 10, total end
    end
    return chosen, count, cost
end
-- Intersect a vertical player-height segment with an expanded oriented box.
-- Ground cylinders often put their thin axis on local X, not local Y.
function Policy.box_risk(point, vertical, size, padding)
    local enter, leave = -4, 12
    for _, axis in ipairs({"X", "Y", "Z"}) do
        local half, origin, direction = size[axis] / 2 + (padding or 3), point[axis], vertical[axis]
        if math.abs(direction) < 0.00001 then
            if math.abs(origin) > half then return 0 end
        else
            local a, b = (-half - origin) / direction, (half - origin) / direction
            if a > b then a, b = b, a end
            enter, leave = math.max(enter, a), math.min(leave, b)
            if enter > leave then return 0 end
        end
    end
    local along = -(point.X * vertical.X + point.Y * vertical.Y + point.Z * vertical.Z)
    along = math.max(enter, math.min(leave, along))
    local edge = 0
    for _, axis in ipairs({"X", "Y", "Z"}) do
        edge = math.max(edge, math.abs(point[axis] + vertical[axis] * along) / (size[axis] / 2 + (padding or 3)))
    end
    return math.max(0.6, 1 - edge * edge * 0.4)
end
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
            and not (item.kind=="ability" and options.loadouts and (record.name==options.loadouts.q or record.name==options.loadouts.e))
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
function Policy.window(pattern, elapsed, extra_lead)
    if not pattern or (pattern.count or 0) < 3 then return false end
    return elapsed >= pattern.mean - math.max(0.6, pattern.sigma * 2) - (extra_lead or 0)
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
function Policy.spacing_feedback(state, now, fraction)
    state.offset = tonumber(state.offset) or 0
    local elapsed = math.max(0, math.min(now - (state.tick or now), 2))
    if fraction and fraction > 0 then
        state.offset = math.min(4, state.offset + math.min(1.5, fraction * 6))
        state.last_hit = now
    elseif now - (state.last_hit or 0) > 8 then
        state.offset = math.max(0, state.offset - elapsed * 0.08)
    end
    state.tick = now
    return state.offset
end
function Policy.target_rank(info)
    local priority = info.role == "healer" and 22 or (info.role == "ranged" and 15 or 0)
    return -info.distance * 0.65 + priority + (1 - info.health) * 14
        + (info.visible and 7 or -10) - (info.crossings or 0) * 26 - (info.danger or 0) * 36
end
function Policy.upgrade_value(item, cost)
    local power = math.max(tonumber(item.score) or 0, 1)
    local gain = math.floor(power + math.max(1, math.min(power * 0.05, 10))) - power
    return gain / power / math.max(cost, 1)
end
function Policy.choose_combo(candidates, now, distance, danger, limit, options)
    if danger >= limit then return nil, "Evading an attack window" end
    local best, score, held
    for _, skill in ipairs(candidates) do
        if skill.cooldown <= 0 and now >= skill.next_ready and distance <= skill.range then
            local allowed = true
            if skill.buff and options.combo then
                allowed = false
                for _, damage in ipairs(candidates) do
                    if not damage.buff and distance <= damage.range and math.max(damage.cooldown, damage.next_ready - now) <= 1.25 then allowed = true end
                end
                if not allowed then held = true end
            end
            if allowed then
                local value = skill.buff and 1000000 or skill.damage / math.max(skill.length, 0.5)
                if not skill.buff and options.aoe and (skill.targets or 1) > 1 then value = value * (1 + math.min(skill.targets - 1, 5) * 0.5) end
                value = value + (skill.priority or 0) * 100 + math.min(now - skill.last_used, 30) * 0.05
                if not score or value > score then best, score = skill, value end
            end
        end
    end
    return best, best and (best.buff and "Buff before burst" or "Ready damage ability") or (held and "Saving buff for a damage cooldown" or "Waiting for cooldown / range")
end

function Policy.predict_aim(position, velocity, lead)
    local horizontal = Vector3.new(velocity.X, 0, velocity.Z)
    if horizontal.Magnitude > 40 then horizontal = horizontal.Unit * 40 end
    return position + horizontal * math.clamp(lead, 0, 0.6)
end
function Policy.compare_runs(history)
    local latest = history[#history]
    if not latest then return "No completed runs to compare" end
    local count, seconds, damage, deaths = 0, 0, 0, 0
    for index = #history - 1, 1, -1 do
        local row = history[index]
        if row.dungeon == latest.dungeon and row.result == latest.result and (not latest.tier or row.tier == latest.tier) then
            count, seconds = count + 1, seconds + (row.duration or 0)
            damage, deaths = damage + (row.damage or 0), deaths + (row.deaths or 0)
            if count >= 5 then break end
        end
    end
    if count == 0 then return "First recorded result for this dungeon / difficulty / outcome" end
    return string.format("Latest vs %d matching results: time %+.0fs | HP lost %+.0f | deaths %+.1f", count,
        (latest.duration or 0) - seconds / count, (latest.damage or 0) - damage / count, (latest.deaths or 0) - deaths / count)
end
function Policy.watchdog(state, now, position, moving)
    if not moving then state.position, state.since, state.stage = nil, nil, 0; return end
    if not state.position or (position - state.position).Magnitude >= 0.75 then
        state.position, state.since, state.stage = position, now, 0
        return
    end
    local elapsed = now - state.since
    local stage = elapsed >= 6 and 3 or (elapsed >= 3.5 and 2 or (elapsed >= 1.8 and 1 or 0))
    if stage > (state.stage or 0) then state.stage = stage; return stage end
end
function Policy.aoe_hold(state, key, now, count, incoming, enabled)
    state[key] = state[key] or {since = now, done = false}
    local row = state[key]
    if not enabled or count > 1 or not incoming or row.done then row.done = true; return false end
    if now - row.since >= 0.65 then row.done = true; return false end
    return true
end
function Policy.select_dungeon(rows, level, preferences, offset, history)
    preferences = preferences or {}
    local rank = {Easy=1,Medium=2,Hard=3,Insane=4,Nightmare=5}
    local eligible = {}
    local allowed = preferences.allowed or {}
    local restricted = next(allowed) ~= nil
    for _, row in ipairs(rows) do
        local difficulty = rank[row[3]]
        if difficulty and type(row[1]) == "number" and row[1] <= level and row[1] >= 1
            and (not restricted or allowed[row[2]] == true)
            and difficulty >= (rank[preferences.minimum] or 1) and difficulty <= (rank[preferences.maximum] or 5) then
            eligible[#eligible + 1] = row
        end
    end
    table.sort(eligible,function(a,b) if a[1]~=b[1] then return a[1]<b[1] end
        if a[2]~=b[2] then return a[2]<b[2] end return rank[a[3]]<rank[b[3]] end)
    if #eligible == 0 then return nil, "No unlocked dungeon matches your filters; edit Dungeons settings" end
    local mode = preferences.mode or "level"
    local index = #eligible
    if mode == "reliable" then
        local newest = eligible[#eligible][2]
        local same_dungeon = {}
        for _,row in ipairs(eligible) do if row[2]==newest then same_dungeon[#same_dungeon+1]=row end end
        local backed = same_dungeon[Policy.adaptive_index(#same_dungeon,(offset or 0)-1)]
        for i,row in ipairs(eligible) do if row==backed then index=i;break end end
    elseif mode == "xp" then
        index = Policy.adaptive_index(#eligible,offset or 0)
    end
    local chosen = eligible[index]
    if mode == "xp" then
        local best, rate
        for i=1,index do
            local row, clears, seconds, xp, failures, samples = eligible[i], 0, 0, 0, 0, 0
            local tier = row[2] .. " / " .. row[3]
            for h=#(history or {}),1,-1 do
                local run=history[h]
                if run.tier==tier then
                    samples=samples+1; seconds=seconds+math.max(run.duration or 0,1)
                    if run.result=="clear" then clears=clears+1; xp=xp+math.max(run.xp or 0,0) else failures=failures+1 end
                    if samples>=6 then break end
                end
            end
            if clears>=2 and xp>0 and seconds>0 then
                local value=xp/seconds * clears/math.max(1,clears+failures)
                if not rate or value>rate then best,rate=row,value end
            end
        end
        if best then return best,"Observed XP/time among tiers with at least two clears; failures reduce ranking" end
        return chosen,"XP history is insufficient; using highest eligible level tier with adaptive backoff"
    end
    return chosen,mode=="reliable" and "Reliable mode: easier unlocked difficulty within the newest eligible dungeon"
        or "Highest level-eligible tier matching filters; saved failure backoff does not lower level mode"
end
function Policy.loadout_plan(items, level, options, mode, locks)
    options = options or {}
    local candidates, current, used, plan = {}, {}, {}, {}
    for _,item in ipairs(items) do
        if item.kind=="ability" then
            for _,slot in ipairs({"q","e"}) do
                if type(item.record.equipped)=="table" and item.record.equipped[slot] then current[slot]=item end
            end
            if item.level<=level and item.ability and item.ability.role~="ignore" and not Policy.locked(item,locks) then
                if item.ability.role=="physical" or item.ability.role=="buff" then candidates[#candidates+1]=item end
            end
        end
    end
    -- A protected or explicitly preferred slot is reserved before ranking either slot.
    for _,slot in ipairs({"q","e"}) do
        local preferred=options[slot]
        if type(preferred)=="string" and preferred~="" then
            plan[slot]=current[slot]
            for _,item in ipairs(items) do
                if item.kind=="ability" and item.level<=level and item.record.name==preferred then plan[slot]=item;break end
            end
            if plan[slot] then used[plan[slot]]=true end
        elseif current[slot] and Policy.locked(current[slot],locks) then plan[slot]=current[slot];used[plan[slot]]=true end
    end
    for _,slot in ipairs({"q","e"}) do
        if not (type(options[slot])=="string" and options[slot]~="") and not plan[slot] then
            local best,score
            for _,item in ipairs(candidates) do
                if not used[item] then
                    local meta=item.ability
                    local other=slot=="q" and plan.e or plan.q
                    local value=(meta.damage or 0)/math.max(meta.cooldown or 1,0.5)
                    if meta.role=="buff" then
                        local damage_available=false
                        for _,candidate in ipairs(candidates) do if candidate~=item and candidate.ability.role=="physical" then damage_available=true end end
                        value=damage_available and 100000 or -1
                        if other and other.ability and other.ability.role=="buff" then value=-1 end
                    elseif mode=="crowd" and (meta.radius or 0)>0 then value=value*2 end
                    if value>=0 and (not score or value>score or (value==score and item.id<(best and best.id or math.huge))) then best,score=item,value end
                end
            end
            plan[slot]=best or current[slot]
            if plan[slot] then used[plan[slot]]=true end
        end
    end
    return plan
end

-- END POLICY
local features = {run_started = nil, outcome = nil, recovery = "Waiting for run", profile = "Balanced",
    inventory = "Gear / selling: current handlers required", telegraphs = "Telegraphs: no verified indicators",
    last_progress = nil, stuck_seconds = 0, last_jump = 0, blocked_targets = {}, death_watch = nil,
    hazards = {}, indicators = setmetatable({}, {__mode = "k"}), safe_zone = nil,
    motion = setmetatable({}, {__mode = "k"}), orbit_sign = 1,
    upgrade_note = "Gold upgrades: waiting", signal_counts = {}}
session.features = features
features.adaptive, features.recent_cues = {offset = 0}, {}
features.recorder, features.failed_routes = {}, {}
if type(session.metrics.native_catalog)=="table" then
    local cached={}
    for _,row in ipairs(session.metrics.native_catalog) do
        if type(row)=="table" and type(row[1])=="number" and row[1]>=1 and row[1]<1000000
            and type(row[2])=="string" and #row[2]<100 and ({Easy=true,Medium=true,Hard=true,Insane=true,Nightmare=true})[row[3]] then
            cached[#cached+1]=row
            if #cached>=200 then break end
        end
    end
    if #cached>0 then features.catalog=cached;features.catalog_note="Native requirements cached from previous lobby" end
end
session.options.dungeons = type(session.options.dungeons) == "table" and session.options.dungeons or {}
if session.options.level_selection_revision ~= 3 then
    session.options.dungeons.mode = "level"
    session.metrics.offset = 0
    session.options.level_selection_revision = 3
end
session.options.loadouts = type(session.options.loadouts) == "table" and session.options.loadouts or {}
session.options.presets = type(session.options.presets) == "table" and session.options.presets or {}
session.options.auto_swing = session.options.auto_swing ~= false
session.options.auto_loadout = session.options.auto_loadout ~= false
session.options.compact_hud = session.options.compact_hud == true
features.watchdog, features.aoe_wait = {}, setmetatable({}, {__mode = "k"})
session.options.boss_profiles = type(session.options.boss_profiles) == "table" and session.options.boss_profiles or {}
session.options.adaptive_dungeons = session.options.adaptive_dungeons ~= false
session.options.predictive_aim = session.options.predictive_aim ~= false
session.options.aoe_wait = session.options.aoe_wait ~= false
local clear_target = tonumber(session.options.clear_target)
session.options.clear_target = clear_target and clear_target == clear_target and math.clamp(clear_target, 30, 1800) or 180
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
session.options.auto_upgrade = session.options.auto_upgrade ~= false
local gold_reserve = tonumber(session.options.gold_reserve)
session.options.gold_reserve = gold_reserve and gold_reserve >= 0 and gold_reserve < 1000000000000 and gold_reserve or 0
session.options.auto_replay = session.options.auto_replay ~= false
session.options.auto_sell = session.options.auto_sell == true
for _, key in ipairs({"adaptive_spacing", "smart_targets", "ability_combos", "aoe_priority", "boss_corrections"}) do session.options[key] = session.options[key] ~= false end
session.options.enemy_roles = type(session.options.enemy_roles) == "table" and session.options.enemy_roles or {}
session.options.upgrade_ranking = session.options.upgrade_ranking == "cheapest" and "cheapest" or "efficient"
local budget = tonumber(session.options.upgrade_budget)
session.options.upgrade_budget = budget and budget >= 0 and budget < 1000000000000 and budget or 0
for _, key in ipairs({"history", "damage_log", "spacing_trials"}) do session.metrics[key] = type(session.metrics[key]) == "table" and session.metrics[key] or {} end
for _, key in ipairs({"upgrade_committed", "upgrade_spent", "damage_taken"}) do
    local value = tonumber(session.metrics[key]); session.metrics[key] = value and value >= 0 and value < 1e15 and value or 0
end
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
gui.DisplayOrder = 10000
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent = player:WaitForChild("PlayerGui")
function features.ui_style(object, surface)
    object.BorderSizePixel = 0
    object.BackgroundColor3 = Color3.fromRGB(surface and 24 or 34, surface and 31 or 45, surface and 44 or 61)
    local corner = Instance.new("UICorner", object); corner.CornerRadius = UDim.new(0, 9)
    local stroke = Instance.new("UIStroke", object); stroke.Color = Color3.fromRGB(55, 75, 96); stroke.Thickness = 1
    stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
end
features.toolbar = {}
local frame = Instance.new("Frame", gui)
features.ui_style(frame, true)
frame.Size = UDim2.fromOffset(460, 348)
frame.Position = UDim2.fromOffset(tonumber(session.options.ui_x) or 20, tonumber(session.options.ui_y) or 100)
frame.BackgroundColor3 = Color3.fromRGB(24, 29, 38)
local function label(text, y, height)
    local item = Instance.new("TextLabel", frame)
    item.Position = UDim2.fromOffset(12, y)
    item.Size = UDim2.new(1, -24, 0, height)
    item.BackgroundTransparency = 1
    item.TextColor3 = Color3.new(1, 1, 1)
    item.TextSize = 15
    item.TextWrapped = true
    item.TextXAlignment = Enum.TextXAlignment.Left
    item.Font = Enum.Font.Gotham
    item.Text = text
    return item
end
features.ui_title = label("DQR Warrior auto v10 R3", 8, 26)
features.ui_title.Size = UDim2.new(1, -180, 0, 26)
features.ui_title.Font = Enum.Font.GothamBold
features.ui_state = label(session.enabled and "RUNNING  |  F8 pauses" or "PAUSED  |  F8 resumes", 36, 20)
features.ui_state.TextColor3 = session.enabled and Color3.fromRGB(93, 216, 195) or Color3.fromRGB(255, 188, 90)
local status = label(note, 64, 138)
local function button(text, y, callback)
    local item = Instance.new("TextButton", frame)
    item.Position = UDim2.fromOffset(12, y)
    item.Size = UDim2.new(1, -24, 0, 34)
    item.BackgroundColor3 = Color3.fromRGB(44, 61, 80)
    item.TextColor3 = Color3.new(1, 1, 1)
    item.TextSize = 15
    item.Text = text
    item.Font = Enum.Font.Gotham
    features.ui_style(item)
    features.toolbar[text] = item
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
    if features.ui_state then
        features.ui_state.Text = session.enabled and "RUNNING  |  F8 pauses" or "PAUSED  |  F8 resumes"
        features.ui_state.TextColor3 = session.enabled and Color3.fromRGB(93, 216, 195) or Color3.fromRGB(255, 188, 90)
    end
    lobby_note = ""
    session.lobby_attempted, session.dungeon_start_sent = false, false
    features.reset_steering = true
    features.wall_route, features.movement_blocked = nil, nil
    features.watchdog, features.escape_until = {}, nil
    features.hold_since, features.escape_until, features.last_progress = nil, nil, nil
    last_path, path_target, waypoints, progress_time, stalled = 0, nil, nil, 0, false
    features.blocked_targets = {}
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

toggle.Position = UDim2.fromOffset(12, 216)
features.toolbar["Dashboard / settings"].Position = UDim2.fromOffset(12, 260)
features.ui_adopt = function(name, parent, y)
    local item = features.toolbar[name]
    if item then item.Parent = parent; item.Position = UDim2.fromOffset(8, y); item.Size = UDim2.new(1, -24, 0, 34); item.ZIndex = 22 end
    return y + 40
end
features.ui_minimize = Instance.new("TextButton", frame)
features.ui_minimize.Position, features.ui_minimize.Size = UDim2.new(1, -48, 0, 8), UDim2.fromOffset(34, 26)
features.ui_minimize.Text, features.ui_minimize.TextColor3 = "-", Color3.new(1, 1, 1)
features.ui_style(features.ui_minimize)
connections[#connections + 1] = features.ui_minimize.Activated:Connect(function()
    features.collapsed = not features.collapsed
    frame.Size = UDim2.fromOffset(460, features.collapsed and 44 or 348)
    features.ui_minimize.Text = features.collapsed and "+" or "-"
    for _, child in ipairs(frame:GetChildren()) do
        if child:IsA("GuiObject") and child ~= features.ui_title and child ~= features.ui_minimize then child.Visible = not features.collapsed end
    end
end)
features.ui_title.Active = true
if Input.InputChanged and Input.InputEnded then
    connections[#connections + 1] = features.ui_title.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 then features.drag = {mouse = input.Position, start = frame.Position} end
    end)
    connections[#connections + 1] = Input.InputChanged:Connect(function(input)
        if features.drag and input.UserInputType == Enum.UserInputType.MouseMovement then
            local delta = input.Position - features.drag.mouse
            local camera = workspace.CurrentCamera
            local viewport = camera and camera.ViewportSize
            local x, y = features.drag.start.X.Offset + delta.X, features.drag.start.Y.Offset + delta.Y
            if viewport then
                local scale = features.ui_scale or 1
                x, y = math.clamp(x, 0, math.max(0, viewport.X - 460 * scale)), math.clamp(y, 0, math.max(0, viewport.Y - (features.collapsed and 44 or 348) * scale))
            end
            frame.Position = UDim2.fromOffset(x, y)
            session.options.ui_x, session.options.ui_y = x, y
        end
    end)
    connections[#connections + 1] = Input.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 then features.drag = nil; save_state() end
    end)
end
for index, name in ipairs({"Combat", "Gear", "Diagnostics"}) do
    local shortcut = Instance.new("TextButton", frame)
    shortcut.Name, shortcut.Text, shortcut.Font = name .. "Shortcut", name, Enum.Font.Gotham
    shortcut.Position, shortcut.Size = UDim2.fromOffset(12 + (index - 1) * 147, 304), UDim2.fromOffset(140, 32)
    shortcut.TextSize, shortcut.TextColor3 = 14, Color3.new(1, 1, 1)
    shortcut.ZIndex = 2
    features.ui_style(shortcut)
    connections[#connections + 1] = shortcut.Activated:Connect(function()
        if features.open_page then features.open_page(name) end
    end)
end
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
            local part = enemy_root(model)
            if part then
                result[#result + 1] = model
                if features and features.motion then
                    local now, previous = os.clock(), features.motion[model]
                    local velocity = part.AssemblyLinearVelocity or Vector3.zero
                    if previous and now - previous.time > 0.05 and now - previous.time < 2 then
                        local delta = (part.Position - previous.position) / (now - previous.time)
                        if velocity.Magnitude < 0.5 then velocity = delta end
                    end
                    velocity = Vector3.new(velocity.X, 0, velocity.Z)
                    if velocity.Magnitude > 40 then velocity = velocity.Unit * 40 end
                    features.motion[model] = {position = part.Position, time = now, velocity = velocity}
                end
            end
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
    output[#output + 1] = "Gold: " .. features.upgrade_note .. "; reserve " .. tostring(session.options.gold_reserve)
    output[#output + 1] = "Boss cue issue: " .. tostring(features.mechanic_note or "none")
    output[#output + 1] = "Version: 10; enabled=" .. tostring(session.enabled) .. "; target=" .. tostring(features.target_reason)
    output[#output + 1] = "Render age: " .. tostring(features.last_render_tick and os.clock() - features.last_render_tick or "not observed")
    output[#output + 1] = "Upgrade budget used: " .. tostring(session.metrics.upgrade_committed or 0)
    local signals = {}
    for key in pairs(features.signal_counts) do signals[#signals + 1] = key end
    table.sort(signals)
    for index, key in ipairs(signals) do
        if index > 50 then break end
        output[#output + 1] = "Cue " .. key .. " x" .. features.signal_counts[key]
    end
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
function features.refresh_catalog()
    local level = features.level and features.level() or 0
    if features.catalog and features.catalog_level == level then return features.catalog end
    local rows, names = {}, {}
    for _,row in ipairs(progression) do rows[#rows+1]=row; names[row[2]]=true end
    local gui_root=player:FindFirstChildOfClass("PlayerGui")
    local queue=gui_root and gui_root:FindFirstChild("queueGui")
    local choose=queue and queue:FindFirstChild("chooseDungeon")
    local left=choose and choose:FindFirstChild("backgroundFillLeft")
    local list=left and left:FindFirstChild("ScrollingFrame")
    if list then
        for _,item in ipairs(list:GetChildren()) do
            if item:IsA("GuiObject") and item.Visible and item:FindFirstChild("chosenIndicatorBackground") then names[item.Name]=true end
        end
    end
    local availability
    local utility=RS:FindFirstChild("Utility")
    local module=utility and utility:FindFirstChild("MapPlaces")
    if module and module:IsA("ModuleScript") then
        local ok,value=pcall(require,module)
        if ok and type(value)=="table" and type(value.IsAvailable)=="function" then availability=value.IsAvailable end
    end
    local remote=remotes:FindFirstChild("getDungeonStats")
    local verified=0
    if remote and remote:IsA("RemoteFunction") and features.rpc then
        local ordered={};for name in pairs(names) do ordered[#ordered+1]=name end;table.sort(ordered)
        for _,name in ipairs(ordered) do
            if not session.alive or not session.enabled then return rows end
            local available=true
            if availability then local ok,value=pcall(availability,name); available=ok and value==true end
            if not available then
                for i=#rows,1,-1 do if rows[i][2]==name then table.remove(rows,i) end end
            else
                lobby_note="Reading native dungeon requirements: " .. name
                local data=features.rpc(remote,name)
                local native={}
                if type(data)=="table" then
                    for _,difficulty in ipairs({"Easy","Medium","Hard","Insane","Nightmare"}) do
                        local info=data[difficulty]
                        local required=type(info)=="table" and tonumber(info.levelReq)
                        if required and required==required and required>=1 and required<1000000 then native[#native+1]={math.ceil(required),name,difficulty} end
                    end
                end
                if #native>0 then
                    for i=#rows,1,-1 do if rows[i][2]==name then table.remove(rows,i) end end
                    for _,row in ipairs(native) do rows[#rows+1]=row end
                    verified=verified+1
                end
            end
        end
    end
    features.catalog,features.catalog_level=rows,level
    session.metrics.native_catalog=rows
    features.catalog_note=verified>0 and (verified .. " native dungeon definitions; bundled fallback for unavailable responses") or "bundled requirements; native definitions unavailable"
    return rows
end

local function own_lobby()
    local games = workspace:FindFirstChild("games")
    local folder = games and games:FindFirstChild("inLobby")
    return folder and folder:FindFirstChild(player.Name)
end
function features.lobby_matches(chosen)
    local lobby=own_lobby()
    if not lobby then return false end
    local map=lobby:FindFirstChild("mapName")
    local difficulty=map and map:FindFirstChild("difficulty")
    if map and map:IsA("StringValue") and map.Value~=chosen[2] then return false end
    if difficulty and difficulty:IsA("StringValue") and difficulty.Value~=chosen[3] then return false end
    return true
end
function features.replace_stale_lobby(chosen)
    if not own_lobby() or features.lobby_matches(chosen) then return end
    local leave=remotes:FindFirstChild("leaveGame")
    assert(leave and leave:IsA("RemoteEvent"),"Old lobby has a different dungeon; leave it and retry")
    lobby_note="Leaving old lobby to create "..chosen[2].." / "..chosen[3]
    leave:FireServer()
    local deadline=os.clock()+10
    while own_lobby() and session.alive and session.enabled and os.clock()<deadline do task.wait(0.1) end
    if session.alive and session.enabled then assert(not own_lobby(),"Old lobby did not close; stopped before starting the wrong dungeon") end
end
task.spawn(function()
    while session.alive do
        if session.enabled and lobby_place and (not features.initial_inventory_done or features.inventory_busy or features.restore_pending or features.gold_pending) then
            lobby_note = "Preparing inventory and Warrior gear"
        elseif session.enabled and lobby_place and not session.lobby_attempted and not session.lobby_busy then
            local stats = player:FindFirstChild("leaderstats")
            local level = stats and stats:FindFirstChild("Level")
            if not level or not tonumber(level.Value) or tonumber(level.Value) < 1 then
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
                    local rows = features.refresh_catalog and features.refresh_catalog() or progression
                    if not session.alive or not session.enabled then return end
                    local chosen, why = Policy.select_dungeon(rows, tonumber(level.Value), session.options.dungeons,
                        session.options.adaptive_dungeons ~= false and session.metrics.offset or 0, session.metrics.history or {})
                    assert(chosen, why)
                    features.selection_reason = why
                    local goal = Policy.goal(session.options, session.metrics, level.Value)
                    if goal then features.set_enabled(false, goal); return end
                    session.options.selection = {dungeon = chosen[2], difficulty = chosen[3]}
                    save_state()
                    session.metrics.selected_tier = chosen[2] .. " / " .. chosen[3]
                    save_state()
                    lobby_note = "Level " .. level.Value .. ": " .. chosen[2] .. " / " .. chosen[3]
                    features.replace_stale_lobby(chosen)
                    if not session.alive or not session.enabled then return end
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
                    assert(features.lobby_matches(chosen),"Server lobby does not match selected dungeon; start cancelled")
                    lobby_note = "Lobby confirmed: "..chosen[2].." / "..chosen[3].." — requesting start"
                    task.wait(1)
                    while session.alive and session.enabled and (features.inventory_busy or features.restore_pending or features.gold_pending) do task.wait(0.2) end
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
        elseif session.enabled and not lobby_place and not session.dungeon_start_sent
            and features.initial_inventory_done and not features.inventory_busy and not features.restore_pending and not features.gold_pending then
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
    if session.options and session.options.smart_targets and features.select_target then return features.select_target(root) end
    local nearest, distance, nearby = nil, math.huge, 0
    for _, model in ipairs(enemies) do
        local part = enemy_root(model)
        if part and (features.blocked_targets[model] or 0) <= os.clock() then
            local candidate = (part.Position - root.Position).Magnitude
            if candidate < 32 then nearby = nearby + 1 end
            if candidate < distance then nearest, distance = model, candidate end
        end
    end
    local current = target and enemy_root(target)
    if current and (features.blocked_targets[target] or 0) <= os.clock()
        and (current.Position - root.Position).Magnitude <= distance * (nearby > 1 and 1.15 or 1.4) then
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
function features.trading()
    local busy = player:FindFirstChild("busyTrading")
    return busy and busy.Value == true
end
function features.upgrade_funds(gold)
    local budget = tonumber(session.options.upgrade_budget) or 0
    if budget <= 0 then return gold end
    return math.min(gold, (tonumber(session.options.gold_reserve) or 0) + math.max(0, budget - (session.metrics.upgrade_committed or 0)))
end
function features.upgrade_gold(items)
    features.gold_pending = false
    if not session.options.auto_upgrade or features.upgrade_blocked then return items end
    local function safe_stage()
        local started = workspace:FindFirstChild("dungeonStarted")
        return lobby_place or features.outcome or (started and started.Value == false)
    end
    if not safe_stage() then features.upgrade_note = "Gold upgrades wait for a break between runs"; return items end
    -- One confirmed native request at a time; at most six requests per pass.
    for _ = 1, 6 do
        if not session.alive or not session.enabled or not session.options.auto_upgrade or features.trading() or not safe_stage() then return items end
        local stats = player:FindFirstChild("leaderstats")
        local gold = stats and stats:FindFirstChild("Gold")
        if not gold or type(gold.Value) ~= "number" then features.upgrade_note = "Gold counter unavailable"; return items end
        local chosen, count = Policy.upgrade_plan(items, features.upgrade_funds(gold.Value), session.options.gold_reserve, session.options.locks, nil, session.options.upgrade_ranking)
        if not chosen then features.upgrade_note = "Gold upgrades: maxed, locked or reserve reached"; return items end
        local upgrade = remotes:FindFirstChild("upgradeItem")
        if not upgrade or not upgrade:IsA("RemoteEvent") then features.upgrade_note = "upgradeItem unavailable"; return items end
        local unequip, equip = remotes:FindFirstChild("unequipItem"), remotes:FindFirstChild("equipItem")
        if not unequip or not equip or not unequip:IsA("RemoteFunction") or not equip:IsA("RemoteFunction") then
            features.upgrade_note = "Gold upgrades need the native equip/unequip handlers"; return items
        end
        features.restore_pending = {kind = chosen.kind, id = chosen.id}
        local changed, change_error = pcall(function()
            features.inventory = "Gold: preparing " .. chosen.kind
            -- The native blacksmith filters out equipped items. Keep its transaction
            -- in this worker so a late unequip reply still reaches restoration.
            assert(unequip:InvokeServer(chosen.kind, chosen.id), "Unequip request rejected")
            if not session.alive or not session.enabled or not session.options.auto_upgrade or not safe_stage() then return end
            local fresh, error_text = features.inventory_snapshot()
            assert(fresh, error_text)
            items = features.observe_inventory(fresh)
            local selected
            for _, item in ipairs(items) do
                if item.kind == chosen.kind and item.id == chosen.id
                    and item.record.UniqueItemID == chosen.record.UniqueItemID and not item.equipped then selected = item end
            end
            assert(selected, "Unequip update unconfirmed")
            local current, amount, quote = Policy.upgrade_plan({selected}, features.upgrade_funds(gold.Value), session.options.gold_reserve, session.options.locks, chosen, session.options.upgrade_ranking)
            if not current or not session.enabled or not session.options.auto_upgrade or features.trading() or not safe_stage() then return end
            count = amount
            local before, unique = tonumber(current.record.currentUpgrade), current.record.UniqueItemID
            features.inventory = "Gold: upgrading " .. chosen.kind .. " (physical, " .. count .. "x)"
            -- Native blacksmith signature: type, number, stat, amount, optional mode.
            session.metrics.upgrade_committed = (session.metrics.upgrade_committed or 0) + quote
            save_state()
            upgrade:FireServer(chosen.kind, chosen.id, "physical", count, count == 10 and "10x" or nil)
            local confirmed, deadline = false, os.clock() + 3
            repeat
                task.wait(0.25)
                if not session.alive or not session.enabled then return items end
                local data = features.inventory_snapshot()
                if data then
                    items = features.observe_inventory(data)
                    for _, item in ipairs(items) do
                        if item.kind == chosen.kind and item.id == chosen.id
                            and (not unique or unique == item.record.UniqueItemID)
                            and (tonumber(item.record.currentUpgrade) or 0) > before then
                            confirmed = true
                            local actual = 0
                            for level = before, item.record.currentUpgrade - 1 do actual = actual + Policy.upgrade_cost(level) end
                            session.metrics.upgrade_committed = math.max(0, session.metrics.upgrade_committed - math.max(0, quote - actual))
                            session.metrics.upgrade_spent = (session.metrics.upgrade_spent or 0) + actual
                            features.upgrade_note = "Gold: " .. chosen.kind .. " " .. item.record.currentUpgrade .. "/" .. item.record.maxUpgrades
                            break
                        end
                    end
                end
            until confirmed or os.clock() >= deadline or not session.enabled
            if not session.enabled then return end
            assert(confirmed, "Gold upgrade unconfirmed; retry in Settings")
        end)
        -- Restore even when paused, closed, a goal fires, or the upgrade fails.
        local restored, accepted = pcall(equip.InvokeServer, equip, chosen.kind, chosen.id)
        if restored and accepted then
            features.restore_pending = nil
            if session.alive and session.enabled then
                local fresh = features.inventory_snapshot()
                if fresh then items = features.observe_inventory(fresh) else restored = false end
                local confirmed = false
                for _, item in ipairs(items) do
                    if item.kind == chosen.kind and item.id == chosen.id and item.equipped then confirmed = true end
                end
                restored = restored and confirmed
            end
        else restored = false end
        if not changed or not restored then
            features.upgrade_blocked = true
            if not restored then features.restore_pending = {kind = chosen.kind, id = chosen.id} end
            features.upgrade_note = not restored and ("Re-equip unconfirmed: " .. chosen.kind .. ":" .. chosen.id)
                or tostring(change_error)
            error(features.upgrade_note)
        end
    end
    local stats = player:FindFirstChild("leaderstats")
    local gold = stats and stats:FindFirstChild("Gold")
    features.gold_pending = session.enabled and session.options.auto_upgrade and gold
        and Policy.upgrade_plan(items, features.upgrade_funds(gold.Value), session.options.gold_reserve, session.options.locks, nil, session.options.upgrade_ranking) ~= nil or false
    return items
end
function features.recover_gear(items)
    local pending = features.restore_pending
    if not pending then return items end
    local function ready(records)
        for _, item in ipairs(records) do if item.kind == pending.kind and item.equipped then return true end end
    end
    if not ready(items) then
        local equip = remotes:FindFirstChild("equipItem")
        assert(equip and equip:IsA("RemoteFunction"), "Waiting for equipment restoration handler")
        assert(features.rpc(equip, pending.kind, pending.id), "Equipment restoration pending")
        local fresh, err = features.inventory_snapshot()
        assert(fresh, err)
        items = features.observe_inventory(fresh)
        assert(ready(items), "Equipment restoration not confirmed")
    end
    features.restore_pending = nil
    return items
end
function features.observe_inventory(data)
    if not session.alive then return {} end
    local items = Policy.inventory_items(data)
    features.preview_items = items
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
        if baseline and not seen[identity] and features.run_stats and #features.run_stats.drops < 12 then
            features.run_stats.drops[#features.run_stats.drops + 1] = tostring(record.name or item.kind)
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
function features.inventory_preview()
    local items, lines = features.preview_items, {"NEXT GEAR PLAN (latest snapshot; refreshed before actions)"}
    if not items then return "Waiting for an inventory snapshot" end
    for _, kind in ipairs({"weapon", "chest", "helmet"}) do
        local item = Policy.best_gear(items, features.level() or 0, session.options.locks)[kind]
        local current
        for _, candidate in ipairs(items) do if candidate.kind == kind and candidate.equipped then current = candidate; break end end
        if item and not item.equipped then
            lines[#lines + 1] = string.format("Change %s: physical %+.0f | health %+.0f", kind,
                item.score - (current and current.score or 0), item.health - (current and current.health or 0))
        end
        if item then lines[#lines + 1] = kind .. ": " .. tostring(item.record.name or item.id) .. " | physical " .. item.score
            .. (item.equipped and " | equipped" or (session.options.auto_equip and " | will equip: best usable physical stat" or " | auto-equip OFF")) end
    end
    local funds = features.upgrade_funds(features.counter("Gold") or 0)
    local item, amount, cost = Policy.upgrade_plan(items, funds, session.options.gold_reserve, session.options.locks, nil, session.options.upgrade_ranking)
    lines[#lines + 1] = item and ("Upgrade " .. tostring(item.record.name or item.id) .. " x" .. amount .. " | quote " .. cost
        .. " gold | " .. session.options.upgrade_ranking .. (session.options.auto_upgrade and "" or " | upgrades OFF")) or "Upgrade: no affordable eligible equipped item"
    local payload, count = Policy.sale(items, session.options, features.level() or 0)
    lines[#lines + 1] = "Sale candidates: " .. count .. (session.options.auto_sell and " | selling ON" or " | selling OFF")
    local shown = 0
    for _, candidate in ipairs(items) do
        for _, identity in ipairs(payload[candidate.kind]) do
            if identity:match("^(%d+):") == tostring(candidate.id) and shown < 12 then
                lines[#lines + 1] = "Sell: " .. tostring(candidate.record.name or candidate.id) .. " | allowed rarity, unequipped, unprotected"
                shown = shown + 1
            end
        end
    end
    return table.concat(lines, "\n")
end
function features.record_movement(root, direction, reason, navigation)
    local now=os.clock()
    if now-(features.last_record or -math.huge)<0.2 then return end
    features.last_record=now
    local p=root.Position
    local row={at=now,position={x=p.X,y=p.Y,z=p.Z},command={x=direction.X,z=direction.Z},
        target=target and target.Name or "none",reason=reason,blocked=features.movement_blocked==true,
        recovery=features.recovery,path=path_note,waypoint=waypoint_index,stage=features.watchdog and features.watchdog.stage or 0,
        wall=features.wall_sample and now-features.wall_sample.at<1 and features.wall_sample or nil}
    features.recorder[#features.recorder+1]=row
    while #features.recorder>80 do table.remove(features.recorder,1) end
end
function features.remember_route(position, direction, navigation)
    direction=flat(direction)
    if direction.Magnitude<0.05 then return end
    local now=os.clock()
    features.failed_routes=features.failed_routes or {}
    for i=#features.failed_routes,1,-1 do
        local row=features.failed_routes[i]
        if now>row.expires or (row.position-position).Magnitude<2 and row.direction:Dot(direction.Unit)>0.8 then table.remove(features.failed_routes,i) end
    end
    features.failed_routes[#features.failed_routes+1]={position=position,direction=direction.Unit,expires=now+25}
    while #features.failed_routes>24 do table.remove(features.failed_routes,1) end
end
function features.route_penalty(position, direction, now)
    if direction.Magnitude<0.01 then return 0 end
    local penalty=0
    for i=#features.failed_routes,1,-1 do
        local row=features.failed_routes[i]
        if now>row.expires then table.remove(features.failed_routes,i)
        elseif (row.position-position).Magnitude<5 then
            penalty=math.max(penalty,math.max(0,row.direction:Dot(direction.Unit)-0.5)*30)
        end
    end
    return penalty
end
function features.stuck_report()
    local routes={}
    for _,row in ipairs(features.failed_routes) do routes[#routes+1]={position={x=row.position.X,y=row.position.Y,z=row.position.Z},
        direction={x=row.direction.X,z=row.direction.Z},remaining=math.max(0,row.expires-os.clock())} end
    return Http:JSONEncode({version="v10 R3",place=game.PlaceId,enabled=session.enabled,level=features.level(),
        movement=movement_note,path=path_note,recovery=features.recovery,samples=features.recorder,failed_routes=routes})
end
function features.classify_abilities(items)
    local templates=RS:FindFirstChild("abilities")
    for _,item in ipairs(items) do
        if item.kind=="ability" then
            local record=item.record
            local template=templates and templates:FindFirstChild(tostring(record.name or ""))
            local function native(name,fallback)
                local value=template and template:FindFirstChild(name)
                if value and (value:IsA("NumberValue") or value:IsA("IntValue") or value:IsA("StringValue")) then return value.Value end
                return record[name] or fallback
            end
            local overrides=session.options.loadouts.roles or {}
            local override=overrides[record.name]
            local text=(tostring(native("abilityType","")) .. " " .. tostring(native("type","")) .. " " .. tostring(record.description or "")):lower()
            local role=Policy.is_buff(tostring(record.name or ""),template and template:FindFirstChild("buffPower")~=nil) and "buff" or nil
            if not role and (text:find("physical",1,true) or text:find("warrior",1,true)) then role="physical" end
            if type(override)=="table" then role=override.role end
            item.ability={role=role,damage=tonumber(native("damage",0)) or 0,cooldown=tonumber(native("cooldownLength",1)) or 1,
                radius=type(override)=="table" and tonumber(override.radius) or tonumber(native("radius",0)) or 0}
        end
    end
    return items
end
function features.loadout_mode()
    if session.options.loadouts.mode=="boss" or session.options.loadouts.mode=="crowd" then return session.options.loadouts.mode end
    for _,model in ipairs(enemies) do
        if model:GetAttribute("IsBoss")==true or model.Name:lower():find("boss",1,true) then return "boss" end
    end
    return "crowd"
end
function features.apply_loadout(items)
    if not session.enabled or features.loadout_blocked or features.restore_pending or features.trading() or os.clock()-(features.last_loadout or -math.huge)<10 then return items end
    local character,_,root=character_parts()
    local casting=character and character:FindFirstChild("busyCasting")
    if casting and casting.Value then return items end
    local started=workspace:FindFirstChild("dungeonStarted")
    if not lobby_place and started and started.Value and not features.outcome then
        if not root then return items end
        for _,model in ipairs(enemies) do local part=enemy_root(model)
            if part and (part.Position-root.Position).Magnitude<30 then features.loadout_note="Loadout waits until enemies are farther than 30 studs";return items end
        end
    end
    features.last_loadout=os.clock()
    items=features.classify_abilities(items)
    local mode=features.loadout_mode()
        local plan=Policy.loadout_plan(items,features.level() or 0,session.options.loadouts,mode,session.options.locks)
    if plan.q and plan.q==plan.e then features.loadout_note="Preferred slots conflict; choose two different abilities"; return items end
    local remote=remotes:FindFirstChild("equipItem")
    if not remote or not remote:IsA("RemoteFunction") then return items end
    for _,slot in ipairs({"q","e"}) do
        local chosen=plan[slot]
        if chosen and not (type(chosen.record.equipped)=="table" and chosen.record.equipped[slot]) then
            if not session.enabled then return items end
            local accepted,err=features.rpc(remote,"ability",chosen.id,slot)
            assert(accepted,"Ability equip: " .. tostring(err or "rejected"))
            local data,message=features.inventory_snapshot();assert(data,"Ability inventory refresh: " .. tostring(message))
            items=features.observe_inventory(data)
            local confirmed=false
            for _,item in ipairs(items) do
                if item.kind=="ability" and item.id==chosen.id and type(item.record.equipped)=="table" and item.record.equipped[slot] then confirmed=true end
            end
            assert(confirmed,"Ability slot update unconfirmed; stopping inventory pass")
        end
    end
    features.loadout_note="Loadout " .. mode .. " | Q: " .. (plan.q and tostring(plan.q.record.name) or "unchanged")
        .. " | E: " .. (plan.e and tostring(plan.e.record.name) or "unchanged")
    return items
end
function features.preset(name, saving)
    local keys={"profile","auto_replay","adaptive_dungeons","clear_target","dungeons","loadouts","auto_equip","auto_upgrade","gold_reserve",
        "upgrade_budget","upgrade_ranking","auto_sell","sell_rarities","sell_abilities","locks","abilities","adaptive_spacing","smart_targets",
        "ability_combos","aoe_priority","boss_corrections","boss_profiles","predictive_aim","aoe_wait","auto_loadout","auto_swing","compact_hud"}
    local function copy(value)
        if type(value)~="table" then return value end
        local result={};for key,item in pairs(value) do result[key]=copy(item) end;return result
    end
    if saving then
        local stored={spacing=config.spacing}
        for _,key in ipairs(keys) do stored[key]=copy(session.options[key]) end
        session.options.presets[name]=stored
        save_state();return true
    end
    if features.inventory_busy or features.restore_pending or session.lobby_busy then features.recovery="Wait for current inventory / lobby request before applying a preset";return false end
    local stored=session.options.presets[name]
    local builtin=not stored
    if not stored then
        local defaults={Farming={profile="Balanced",dungeons={mode="reliable"},auto_replay=true,auto_swing=true},
            Leveling={profile="Balanced",dungeons={mode="level"},auto_replay=true,auto_swing=true},
            Boss={profile="Conservative",dungeons={mode="reliable"},loadouts={mode="boss"},auto_swing=true}}
        stored=defaults[name]
    end
    if not stored then features.recovery="Save this preset first";return false end
    for _,key in ipairs(keys) do
        if stored[key]~=nil then
            if builtin and type(stored[key])=="table" then
                local merged=copy(session.options[key] or {})
                for field,value in pairs(stored[key]) do merged[field]=copy(value) end
                session.options[key]=merged
            else session.options[key]=copy(stored[key]) end
        end
    end
    if stored.spacing then config.spacing=math.clamp(stored.spacing,6,12);saved_state.spacing=config.spacing end
    features.reset_steering,features.inventory_due=true,true
    features.profile=session.options.profile;save_state()
    if features.ensure_ui then features.ui_error="Preset refresh";features.ensure_ui() end
    features.recovery="Preset applied: " .. name
    return true
end

function features.inventory_pass()
    if features.inventory_busy then return end
    if features.trading and features.trading() then features.inventory = "Inventory waiting for trade to finish"; return end
    features.inventory_busy = true
    local ok, err = pcall(function()
        local data, error_text = features.inventory_snapshot()
        assert(data, error_text)
        local items = features.observe_inventory(data)
        if not session.enabled then return end
        if features.restore_pending then items = features.recover_gear(items) end
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
        if session.enabled and session.options.auto_loadout and features.apply_loadout then items = features.apply_loadout(items) end
        if session.enabled and session.options.auto_upgrade then items = features.upgrade_gold(items) end
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
        features.inventory = "Inventory: " .. #items .. " items; " .. (features.upgrade_note or "Warrior gear / locks applied")
    end)
    features.initial_inventory_done, features.inventory_busy = true, false
    if not ok then
        features.inventory = "Inventory: " .. tostring(err)
        if tostring(err):find("Ability",1,true) then
            features.loadout_blocked=true
            features.loadout_note="Loadout update unconfirmed; use Retry ability loadouts after checking slots"
        end
    end
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
        if session.enabled and (not features.initial_inventory_done or features.inventory_due or features.gold_pending or os.clock() - last >= 15) then
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

function features.counter(name)
    local stats = player:FindFirstChild("leaderstats")
    local value = stats and stats:FindFirstChild(name)
    return value and tonumber(value.Value)
end
function features.ensure_run()
    local token = game.JobId .. "/" .. session.metrics.round
    if features.run_stats and features.run_stats.token == token then return features.run_stats end
    local dungeon = workspace:FindFirstChild("dungeonName")
    features.run_stats = {token = token, started = os.time(), tier = session.metrics.selected_tier, damage = 0, hits = 0, deaths = 0,
        dungeon = dungeon and dungeon:IsA("StringValue") and dungeon.Value or ("Place " .. tostring(game.PlaceId)),
        gold_start = features.counter("Gold"), xp_start = session.metrics.observed_xp or 0, drops = {},
        adaptive_seconds = 0, offset_sum = 0}
    return features.run_stats
end
function features.refresh_run()
    local row = features.run_stats
    if not row then return end
    local gold = features.counter("Gold")
    row.gold_net = gold and row.gold_start and gold - row.gold_start or nil
    row.xp = math.max(0, (session.metrics.observed_xp or 0) - row.xp_start)
end
function features.end_run(kind, duration)
    local row = features.ensure_run()
    if row.result then return end
    row.result, row.duration = kind, duration
    features.refresh_run()
    session.metrics.history[#session.metrics.history + 1] = row
    while #session.metrics.history > 20 do table.remove(session.metrics.history, 1) end
end
function features.damage_event(amount, maximum, health)
    if lobby_place or features.outcome or not session.enabled or amount <= 0 or maximum <= 0
        or amount ~= amount or maximum ~= maximum or amount == math.huge then return end
    local started = workspace:FindFirstChild("dungeonStarted")
    if not started or not started.Value then return end
    local row = features.ensure_run()
    row.damage, row.hits = row.damage + amount, row.hits + 1
    session.metrics.damage_taken = (session.metrics.damage_taken or 0) + amount
    local fraction = math.min(amount / maximum, 1)
    local prior_spacing = config.spacing + (features.adaptive.offset or 0)
    local bucket = tostring(math.floor((features.adaptive.offset or 0) * 2) / 2)
    local trial = session.metrics.spacing_trials[bucket] or {seconds = 0, loss = 0, hits = 0}
    session.metrics.spacing_trials[bucket] = trial
    trial.loss, trial.hits = trial.loss + fraction, trial.hits + 1
    if session.options.adaptive_spacing then Policy.spacing_feedback(features.adaptive, os.clock(), fraction) end
    local cues = {}
    for _, cue in ipairs(features.recent_cues) do
        if os.clock() - cue.at <= 2.5 and #cues < 4 then cues[#cues + 1] = cue.key end
    end
    local entry = {at = os.time(), lost = amount, health = health, target = target and target.Name or "none",
        movement = movement_note, spacing = prior_spacing, cues = cues}
    session.metrics.damage_log[#session.metrics.damage_log + 1] = entry
    while #session.metrics.damage_log > 40 do table.remove(session.metrics.damage_log, 1) end
end
function features.combat_tick()
    if not session.enabled then features.stop_reason = note end
    local started = workspace:FindFirstChild("dungeonStarted")
    if session.enabled and not lobby_place and started and started.Value and not features.outcome then
        local row = features.ensure_run()
        Policy.spacing_feedback(features.adaptive, os.clock())
        local offset = session.options.adaptive_spacing and features.adaptive.offset or 0
        row.adaptive_seconds, row.offset_sum = row.adaptive_seconds + 1, row.offset_sum + offset
        local key = tostring(math.floor(offset * 2) / 2)
        local trial = session.metrics.spacing_trials[key] or {seconds = 0, loss = 0, hits = 0}
        session.metrics.spacing_trials[key] = trial
        trial.seconds = trial.seconds + 1
    end
    features.refresh_run()
    if features.route_label then features.route_label.Text = "Movement samples: " .. #features.recorder .. " / 80 | Failed approaches: " .. #features.failed_routes
        .. "\n" .. (features.recovery or "Ready") end
    if features.dungeon_label then
        local rows = features.catalog or progression
        local chosen, why = Policy.select_dungeon(rows, features.level() or 0, session.options.dungeons,
            session.options.adaptive_dungeons and session.metrics.offset or 0, session.metrics.history)
        features.dungeon_label.Text = "Detected level: " .. tostring(features.level() or "loading") .. "\nNext: "
            .. (chosen and chosen[2] .. " / " .. chosen[3] or "none eligible") .. "\n" .. why
            .. "\nCatalogue: " .. (features.catalog_note or "bundled fallback")
    end
    if features.preview_label then features.preview_label.Text = features.inventory_preview() end
    if features.loadout_label then features.loadout_label.Text = features.loadout_note or "Loadout: waiting for classified physical abilities" end
    if features.boss_label then
        local cue = features.recent_cues[#features.recent_cues]
        features.boss_label.Text = "Enemy: " .. (target and target.Name or "none") .. "\nLatest cue: "
            .. (cue and os.clock() - cue.at < 8 and cue.key or "none recently")
            .. "\nResponse: " .. movement_note .. "\n" .. features.telegraphs
            .. "\nProfile: " .. (target and session.options.boss_profiles[target.Name] or "automatic")
            .. "\nUnknown cues rely on visible indicators and learned timings."
    end
    features.stop_reason = session.enabled and movement_note or note
    if features.ui_state then
        features.ui_state.Text = session.enabled and "RUNNING  |  F8 pauses" or "PAUSED  |  F8 resumes"
    end
    if features.history_label then
        local lines = {"RECENT RUNS  |  Last 20 results", Policy.compare_runs(session.metrics.history)}
        for index = #session.metrics.history, math.max(1, #session.metrics.history - 9), -1 do
            local row = session.metrics.history[index]
            lines[#lines + 1] = tostring(row.dungeon or "Dungeon") .. "\n" .. string.format("%s  %ds  |  Lost HP %.0f  | Hits %d  |  Deaths %d\nXP %s  |  Net gold %s  |  New drops %d",
                tostring(row.result), row.duration or 0, row.damage or 0, row.hits or 0, row.deaths or 0,
                tostring(row.xp or 0), row.gold_net and tostring(row.gold_net) or "unavailable", #(row.drops or {}))
        end
        features.history_label.Text = table.concat(lines, "\n\n")
    end
    if features.damage_label then
        local lines = {"RECENT HEALTH LOSSES  |  Recent cues are context, not confirmed causes"}
        for index = #session.metrics.damage_log, math.max(1, #session.metrics.damage_log - 5), -1 do
            local row = session.metrics.damage_log[index]
            lines[#lines + 1] = string.format("Lost %.0f HP | %s | Spacing %.1f\n%s\n%s", row.lost, row.target, row.spacing, row.movement, table.concat(row.cues, "; "))
        end
        features.damage_label.Text = table.concat(lines, "\n\n")
    end
    if features.feedback_label then
        local lines = {string.format("Extra spacing: %.1f studs | Upgrade budget used: %.0f / %s\nTarget: %s\nMovement: %s",
            features.adaptive.offset or 0, session.metrics.upgrade_committed or 0,
            session.options.upgrade_budget > 0 and tostring(session.options.upgrade_budget) or "unlimited",
            features.target_reason or "nearest eligible enemy", features.stop_reason)}
        local count = 0
        for key, trial in pairs(session.metrics.spacing_trials) do
            if trial.seconds >= 15 and count < 3 then
                count = count + 1
                lines[#lines + 1] = string.format("+%s studs: %.1f%% max HP lost/min over %ds", key, trial.loss / trial.seconds * 6000, trial.seconds)
            end
        end
        features.feedback_label.Text = table.concat(lines, "\n")
    end
end
function features.role(model)
    local override = session.options.enemy_roles[model.Name]
    if override then return override, "override" end
    local value = model:GetAttribute("role") or model:GetAttribute("enemyType") or ""
    local name = (tostring(value) .. " " .. model.Name):lower()
    if name:find("healer", 1, true) or name:find("medic", 1, true) or name:find("priest", 1, true) then return "healer", "name/attribute hint" end
    for _, word in ipairs({"mage", "wizard", "archer", "ranged", "artillery", "gunner", "caster"}) do
        if name:find(word, 1, true) then return "ranged", "name/attribute hint" end
    end
    return "melee", "default"
end
function features.select_target(root)
    local records, nearest = {}, math.huge
    for _, model in ipairs(enemies) do
        local part = enemy_root(model)
        if part then
            local distance = (part.Position - root.Position).Magnitude
            nearest = math.min(nearest, distance)
            records[#records + 1] = {model = model, part = part, distance = distance}
        end
    end
    local best, best_score, current_score, reason
    local params = ray_params(player.Character)
    for _, item in ipairs(records) do
        local role, hint = features.role(item.model)
        if role ~= "ignore" and item.distance <= nearest + 26 then
            local crossings = 0
            local line = flat(item.part.Position - root.Position)
            for _, other in ipairs(records) do
                if other ~= item and line.Magnitude > 0.1 then
                    local relative = flat(other.part.Position - root.Position)
                    local along = relative:Dot(line) / line:Dot(line)
                    if along > 0.15 and along < 0.9 and (relative - line * along).Magnitude < 4.5 then crossings = crossings + 1 end
                end
            end
            local humanoid = item.model:FindFirstChildOfClass("Humanoid")
            local ratio = humanoid and humanoid.MaxHealth > 0 and humanoid.Health / humanoid.MaxHealth or 1
            local visible = clear_path(root, item.part.Position, params)
            local midpoint = root.Position + (item.part.Position - root.Position) * 0.5
            local danger = features.hazard_risk and features.hazard_risk(midpoint, os.clock() + 0.4) or 0
            local score = Policy.target_rank({distance = item.distance, role = role, health = ratio, visible = visible, crossings = crossings, danger = danger})
            if (features.blocked_targets[item.model] or 0) > os.clock() then score = score - 60 end
            if item.model == target then current_score = score end
            if not best_score or score > best_score then best, best_score, reason = item.model, score, role .. " | " .. hint end
        end
    end
    if target and current_score and current_score >= (best_score or -math.huge) - 5 then return target end
    features.target_reason = reason or "No eligible target"
    return best
end

function features.finish(outcome)
    if not session.alive or lobby_place or features.outcome then return end
    local token = game.JobId .. "/" .. session.metrics.round
    if session.metrics.last_outcome == token then return end
    session.metrics.last_outcome = token
    local duration = math.max(0, os.time() - (features.run_started or os.time()))
    if features.end_run then features.end_run(outcome, duration) end
    local previous_offset = session.metrics.offset
    if session.options.adaptive_dungeons ~= false then
        Policy.record_outcome(session.metrics, outcome, duration, session.options.clear_target or 180)
    else
        Policy.record_outcome(session.metrics, outcome, duration, session.options.clear_target or 180)
        session.metrics.offset = previous_offset
    end
    features.progression_changed = previous_offset ~= session.metrics.offset
    if Policy.select_dungeon and session.metrics.selected_tier then
        local next_row=Policy.select_dungeon(features.catalog or progression,features.level() or 0,session.options.dungeons,
            session.options.adaptive_dungeons and session.metrics.offset or 0,session.metrics.history)
        if next_row and next_row[2] .. " / " .. next_row[3] ~= session.metrics.selected_tier then features.progression_changed=true end
    end
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
function features.connect_started(marker)
    if marker.Name ~= "dungeonStarted" or not marker:IsA("BoolValue") or features.start_marker == marker then return end
    features.start_marker = marker
    local function changed(value)
        if value ~= true or not session.alive then return end
        if features.outcome then session.metrics.round = session.metrics.round + 1; features.outcome = nil end
        features.run_started, features.run_stats = os.time(), nil
        features.ensure_run()
        features.reset_steering, features.hold_since, features.stuck_seconds = true, nil, 0
        last_path, path_target, waypoints = 0, nil, nil
        features.blocked_targets = {}
    end
    connections[#connections + 1] = marker.Changed:Connect(changed)
    if marker.Value then changed(true) end
end
local started_marker = workspace:FindFirstChild("dungeonStarted")
if started_marker then features.connect_started(started_marker) end
connections[#connections + 1] = workspace.ChildAdded:Connect(features.connect_started)
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
    local prefer_return = outcome.kind ~= "clear" or features.progression_changed
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
    if features.inventory_busy or features.restore_pending then features.recovery = "Wait for gear processing before resetting"; return end
    for _, name in ipairs({"clears", "failures", "deaths", "clear_seconds", "active_seconds", "fast_streak", "failure_streak",
        "offset", "cast_started", "cast_failed", "recoveries", "observed_xp", "upgrade_committed", "upgrade_spent", "damage_taken"}) do session.metrics[name] = 0 end
    session.metrics.spacing_trials = {}
    features.adaptive, features.reset_steering = {offset = 0}, true
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
    panel.Position, panel.Size = UDim2.fromScale(0.5, 0.5), UDim2.fromOffset(760, 570)
    panel.BackgroundColor3 = Color3.fromRGB(20, 25, 34)
    panel.ZIndex = 20
    features.settings_panel = panel
    features.ui_style(panel, true)
    local notice=Instance.new("TextLabel",panel)
    notice.Name,notice.Position,notice.Size="SettingsNotice",UDim2.new(0,154,1,-34),UDim2.new(1,-168,0,26)
    notice.ZIndex,notice.BackgroundTransparency,notice.TextColor3,notice.TextSize=22,1,Color3.fromRGB(93,216,195),12
    notice.TextWrapped,notice.Text=true,"Settings save across servers | F8 pauses"
    features.settings_notice=notice
    local close = Instance.new("TextButton", panel)
    close.Text, close.TextSize = "Close settings", 14
    close.ZIndex = 22
    close.Position, close.Size = UDim2.new(1, -108, 0, 10), UDim2.fromOffset(94, 28)
    features.ui_style(close)
    close.BackgroundColor3, close.TextColor3 = Color3.fromRGB(44, 65, 87), Color3.new(1, 1, 1)
    connections[#connections + 1] = close.Activated:Connect(function() panel.Visible = false end)
    local pages, tabs, cursors = {}, {}, {}
    features.ui_pages, features.ui_tabs = pages, tabs
    local scroll, current, y = nil, nil, 0
    local heading = Instance.new("TextLabel", panel)
    heading.Position, heading.Size = UDim2.fromOffset(18, 10), UDim2.fromOffset(500, 28)
    heading.BackgroundTransparency, heading.TextColor3, heading.TextSize = 1, Color3.new(1, 1, 1), 18
    heading.Font, heading.TextXAlignment = Enum.Font.GothamBold, Enum.TextXAlignment.Left
    heading.ZIndex = 22
    local function section(name)
        if scroll then cursors[current] = y; scroll.CanvasSize = UDim2.fromOffset(0, y + 12) end
        current = name
        if not pages[name] then
            local page = Instance.new("ScrollingFrame", panel)
            page.Name = name .. "Page"
            page.Position, page.Size = UDim2.fromOffset(152, 52), UDim2.new(1, -164, 1, -102)
            page.BackgroundTransparency, page.ScrollBarThickness, page.BorderSizePixel = 1, 5, 0
            page.ZIndex, page.Active = 21, true
            page.ClipsDescendants = true
            page.Visible = false
            pages[name] = page
        end
        scroll, y = pages[name], cursors[name] or 0
    end
    features.show_page = function(name)
        if not pages[name] then name = "Overview" end
        session.options.ui_page = name
        features.active_page = name
        for key, page in pairs(pages) do
            page.Visible = key == name
            if key == name then page.CanvasPosition = Vector2.new(0, 0) end
            if tabs[key] then tabs[key].BackgroundColor3 = key == name and Color3.fromRGB(28, 109, 111) or Color3.fromRGB(34, 45, 61) end
        end
        heading.Text = "DQR / " .. name
    end
    for index, name in ipairs({"Overview", "Dungeons", "Combat", "Gear", "Presets", "Goals", "History", "Diagnostics"}) do
        local tab = Instance.new("TextButton", panel)
        tab.Name, tab.Text, tab.Font = name .. "Tab", name, Enum.Font.Gotham
        tab.Position, tab.Size = UDim2.fromOffset(12, 52 + (index - 1) * 44), UDim2.fromOffset(128, 36)
        tab.TextColor3, tab.TextSize = Color3.new(1, 1, 1), 14
        tab.ZIndex = 22
        features.ui_style(tab)
        tabs[name] = tab
        connections[#connections + 1] = tab.Activated:Connect(function() features.show_page(name); save_state() end)
    end
    section("Overview")
    local function text(value, height)
        local item = Instance.new("TextLabel", scroll)
        item.Position, item.Size = UDim2.fromOffset(8, y), UDim2.new(1, -24, 0, height or 28)
        item.BackgroundTransparency, item.TextColor3, item.TextSize = 1, Color3.new(1, 1, 1), 14
        item.TextWrapped, item.TextXAlignment, item.Text = true, Enum.TextXAlignment.Left, value
        item.TextYAlignment = Enum.TextYAlignment.Top
        item.Font = Enum.Font.Gotham
        item.ZIndex = 22
        y = y + (height or 28) + 6
        return item
    end
    local function entry(title, value)
        text(title)
        local item = Instance.new("TextBox", scroll)
        item.Position, item.Size = UDim2.fromOffset(8, y), UDim2.new(1, -24, 0, 32)
        item.Text, item.ClearTextOnFocus, item.TextSize = tostring(value or ""), false, 14
        item.Font = Enum.Font.Gotham
        features.ui_style(item)
        item.ZIndex = 22
        item.BackgroundColor3, item.TextColor3 = Color3.fromRGB(40, 48, 62), Color3.new(1, 1, 1)
        y = y + 38
        return item
    end
    local function action(title, callback)
        local item = Instance.new("TextButton", scroll)
        item.Position, item.Size = UDim2.fromOffset(8, y), UDim2.new(1, -24, 0, 34)
        item.Text, item.TextSize = title, 14
        item.Font = Enum.Font.Gotham
        features.ui_style(item)
        item.ZIndex = 22
        item.BackgroundColor3, item.TextColor3 = Color3.fromRGB(44, 65, 87), Color3.new(1, 1, 1)
        connections[#connections + 1] = item.Activated:Connect(function()
            local previous_notice=features.recovery
            local ok,err=pcall(callback,item)
            local message_bar=features.settings_notice or notice
            message_bar.Text=ok and (features.recovery~=previous_notice and features.recovery or ("Updated: "..item.Text)) or ("Control error: "..tostring(err))
            message_bar.TextColor3=ok and Color3.fromRGB(93,216,195) or Color3.fromRGB(255,188,90)
        end)
        y = y + 40
        return item
    end
    local function option(title, key)
        action(title .. ": " .. (session.options[key] and "ON" or "OFF"), function(item)
            session.options[key] = not session.options[key]
            item.Text = title .. ": " .. (session.options[key] and "ON" or "OFF")
            save_state()
        end)
    end
    features.dashboard = text("Collecting session metrics...", 160)
    features.feedback_label = text("Measuring health loss and spacing...", 156)
    action("HUD: " .. (session.options.compact_hud and "COMPACT" or "DETAILED"), function(item)
        session.options.compact_hud = not session.options.compact_hud
        item.Text = "HUD: " .. (session.options.compact_hud and "COMPACT" or "DETAILED"); save_state()
    end)
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
    section("Dungeons")
    text("LEVEL-AWARE DUNGEON QUEUE",32)
    features.dungeon_label=text("Detecting level and reading native dungeon requirements...",130)
    text("The lobby creates a private dungeon using your current level. Native requirements replace fallback entries when available. Existing lobbies are left intact.",65)
    local dungeon_mode=entry("Selection mode: level, reliable, or xp",session.options.dungeons.mode or "level")
    local allowed_names={}
    for name,allowed in pairs(session.options.dungeons.allowed or {}) do if allowed then allowed_names[#allowed_names+1]=name end end
    table.sort(allowed_names)
    local allowed_input=entry("Allowed dungeons: comma-separated exact names; blank allows all",table.concat(allowed_names,", "))
    local min_difficulty=entry("Minimum difficulty: Easy, Medium, Hard, Insane, Nightmare",session.options.dungeons.minimum or "Easy")
    local max_difficulty=entry("Maximum difficulty",session.options.dungeons.maximum or "Nightmare")
    action("Save dungeon preferences",function()
        local mode=dungeon_mode.Text:lower():match("^%s*(.-)%s*$")
        local valid={Easy=true,Medium=true,Hard=true,Insane=true,Nightmare=true}
        local minimum=min_difficulty.Text:match("^%s*(.-)%s*$")
        local maximum=max_difficulty.Text:match("^%s*(.-)%s*$")
        if not ({level=true,reliable=true,xp=true})[mode] or not valid[minimum] or not valid[maximum] then features.recovery="Use a listed mode and difficulty";return end
        local allowed={}
        for name in allowed_input.Text:gmatch("[^,]+") do local clean=name:match("^%s*(.-)%s*$");if clean~="" then allowed[clean]=true end end
        session.options.dungeons={mode=mode,allowed=allowed,minimum=minimum,maximum=maximum}
        if not session.lobby_busy then session.lobby_attempted=false end
        save_state();features.recovery="Dungeon preferences saved"
    end)
    action("Refresh native dungeon requirements / retry queue",function()
        if session.lobby_busy then features.recovery="Wait for the active lobby request";return end
        features.catalog_level=nil;session.lobby_attempted=false;features.recovery="Queue retry enabled"
    end)
    section("Presets")
    text("SESSION PRESETS",32)
    text("Save your current combat, dungeon, loadout and inventory settings. Applying a preset keeps your pause state and session counters. Unsaved Farming, Leveling and Boss presets provide starting settings.",80)
    local preset_name=entry("Preset name", "Leveling")
    action("Save current settings as preset",function()
        local name=preset_name.Text:match("^%s*(.-)%s*$")
        if name~="" and #name<=50 then features.preset(name,true);features.recovery="Preset saved: "..name end
    end)
    action("Apply named preset",function() features.preset(preset_name.Text:match("^%s*(.-)%s*$"),false) end)
    for _,name in ipairs({"Farming","Leveling","Boss"}) do
        action("Apply "..name.." preset",function() features.preset(name,false) end)
    end

    section("Goals")
    option("Adaptive dungeon progression", "adaptive_dungeons")
    local clear_seconds = entry("Target clear time (seconds): 2 failures step down; 2 fast clears step up", session.options.clear_target)
    action("Save progression target", function()
        local value = tonumber(clear_seconds.Text)
        if value and value == value then session.options.clear_target = math.clamp(value, 30, 1800) end
        clear_seconds.Text = tostring(session.options.clear_target); save_state()
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
    section("Combat")
    option("Auto-swing at nearby enemies", "auto_swing")
    option("Predict enemy movement when aiming", "predictive_aim")
    option("Briefly hold AoE for approaching groups", "aoe_wait")
    features.boss_label = text("Waiting for boss / enemy attack cues", 150)
    local boss_name = entry("Exact boss name for a combat stance override", "")
    local boss_stance = entry("Boss stance: Conservative, Balanced, Aggressive, or auto", "Conservative")
    action("Save boss profile", function()
        local name = boss_name.Text:match("^%s*(.-)%s*$")
        local stance = boss_stance.Text:match("^%s*(.-)%s*$")
        if name ~= "" and ({Conservative=true, Balanced=true, Aggressive=true, auto=true})[stance] then
            session.options.boss_profiles[name] = stance ~= "auto" and stance or nil
            save_state(); features.recovery = "Boss stance saved; verified cue handlers remain active"
        else features.recovery = "Enter an exact name and a listed stance" end
    end)
    option("Damage-aware spacing", "adaptive_spacing")
    option("Safer target priority", "smart_targets")
    option("Buff / damage combinations", "ability_combos")
    option("Clustered-target AoE priority", "aoe_priority")
    option("Repeated-hit dodge corrections", "boss_corrections")
    y = features.ui_adopt("Enemy spacing: ON", scroll, y)
    y = features.ui_adopt("Spacing: " .. config.spacing .. " studs — click to change", scroll, y)
    local enemy_name = entry("Exact enemy name for a role override", "")
    local enemy_role = entry("Role: healer, ranged, melee, ignore, or auto", "auto")
    action("Save enemy role", function()
        local name = enemy_name.Text:match("^%s*(.-)%s*$")
        local role = enemy_role.Text:lower():match("^%s*(.-)%s*$")
        if name ~= "" and ({healer=true, ranged=true, melee=true, ignore=true, auto=true})[role] then
            session.options.enemy_roles[name] = role ~= "auto" and role or nil
            save_state(); features.recovery = "Enemy role saved: " .. name
        else features.recovery = "Enter a name and one of the listed roles" end
    end)
    text("Ability overrides follow the equipped tool name when you change slots.", 40)
    local slot = "q"
    action("Edit active slot: Q", function(item) slot = slot == "q" and "e" or "q"; item.Text = "Edit active slot: " .. slot:upper() end)
    local range = entry("Ability range in studs; 0 uses automatic range", 0)
    local priority = entry("Priority adjustment (-5 to 5)", 0)
    local duration = entry("Buff duration in seconds; 0 leaves automatic behavior", 0)
    local aoe_radius = entry("AoE radius: 0 reads the native radius if available", 0)
    local aim_lead = entry("Aim prediction time in seconds (0 to 0.6); default 0.15", 0.15)
    action("Save profile for currently equipped ability", function()
        local containers = {player:FindFirstChildOfClass("Backpack"), player.Character}
        for _, container in pairs(containers) do
            if container then
                for _, tool in ipairs(container:GetChildren()) do
                    local value = tool:FindFirstChild("abilitySlot")
                    if tool:IsA("Tool") and value and value.Value == slot then
                        session.options.abilities[tool.Name] = {range = math.clamp(tonumber(range.Text) or 0, 0, 150),
                            priority = math.clamp(tonumber(priority.Text) or 0, -5, 5),
                            buff_duration = math.clamp(tonumber(duration.Text) or 0, 0, 300),
                            aim_lead = math.clamp(tonumber(aim_lead.Text) or 0.15, 0, 0.6),
                            aoe_radius = math.clamp(tonumber(aoe_radius.Text) or 0, 0, 80)}
                        save_state(); features.recovery = "Ability profile saved: " .. tool.Name
                        return
                    end
                end
            end
        end
        features.recovery = "No ability found in slot " .. slot:upper()
    end)
    section("Gear")
    option("Automatic Warrior ability loadouts", "auto_loadout")
    action("Loadout context: " .. (session.options.loadouts.mode or "auto"),function(item)
        local next_mode={auto="crowd",crowd="boss",boss="auto"}
        session.options.loadouts.mode=next_mode[session.options.loadouts.mode or "auto"] or "auto"
        item.Text="Loadout context: "..session.options.loadouts.mode;features.inventory_due=true;save_state()
    end)
    text("Loadouts use owned abilities with explicit physical metadata or saved roles. Preferred slots are protected; unclassified abilities are not selected automatically. Changes wait for a quiet moment.", 80)
    action("Retry ability loadouts",function()
        features.loadout_blocked,features.last_loadout,features.inventory_due=false,nil,true
        features.loadout_note="Loadout retry enabled"
    end)
    local ability_name = entry("Exact owned ability name", "")
    local ability_role = entry("Ability role: physical, buff, ignore, or auto", "auto")
    local ability_radius = entry("Known area radius for this ability; 0 = native radius / single target", 0)
    action("Save ability role", function()
        local name = ability_name.Text:match("^%s*(.-)%s*$")
        local role = ability_role.Text:lower():match("^%s*(.-)%s*$")
        if name ~= "" and ({physical=true,buff=true,ignore=true,auto=true})[role] then
            session.options.loadouts.roles = session.options.loadouts.roles or {}
            session.options.loadouts.roles[name] = role ~= "auto" and {role=role,radius=math.clamp(tonumber(ability_radius.Text) or 0,0,80)} or nil
            features.inventory_due=true; save_state()
        end
    end)
    local preferred_q = entry("Protected Q ability name; blank lets loadout choose", session.options.loadouts.q)
    local preferred_e = entry("Protected E ability name; blank lets loadout choose", session.options.loadouts.e)
    action("Save preferred ability slots", function()
        session.options.loadouts.q=preferred_q.Text:match("^%s*(.-)%s*$")
        session.options.loadouts.e=preferred_e.Text:match("^%s*(.-)%s*$")
        features.inventory_due=true;save_state()
    end)
    features.loadout_label = text("Loadout: waiting for inventory", 70)
    features.preview_label = text("Waiting for inventory plan", 340)
    action("Refresh inventory preview", function() features.inventory_due = true end)
    action("Copy inventory preview", function()
        if type(setclipboard) == "function" then pcall(setclipboard, features.inventory_preview()) end
    end)
    action("Auto-equip Warrior gear: " .. tostring(session.options.auto_equip), function(item)
        session.options.auto_equip = not session.options.auto_equip
        item.Text = "Auto-equip Warrior gear: " .. tostring(session.options.auto_equip)
        features.inventory_due = true; save_state()
    end)
    action("Retry stat spending", function() if features.retry_stats then features.retry_stats() end end)
    action("Gold upgrades (physical): " .. tostring(session.options.auto_upgrade), function(item)
        session.options.auto_upgrade = not session.options.auto_upgrade
        item.Text = "Gold upgrades (physical): " .. tostring(session.options.auto_upgrade)
        features.inventory_due = true; save_state()
    end)
    local reserve = entry("Keep this much gold; 0 allows all available gold", session.options.gold_reserve)
    action("Save gold reserve", function()
        local value = tonumber(reserve.Text)
        if value and value == value then session.options.gold_reserve = math.clamp(math.floor(value), 0, 999999999999) end
        reserve.Text = tostring(session.options.gold_reserve)
        features.inventory_due = true; save_state()
    end)
    local budget_input = entry("Session upgrade budget: 0 is unlimited", session.options.upgrade_budget)
    action("Save upgrade budget", function()
        local amount = tonumber(budget_input.Text)
        if amount and amount == amount then session.options.upgrade_budget = math.clamp(math.floor(amount), 0, 999999999999) end
        features.inventory_due = true; budget_input.Text = tostring(session.options.upgrade_budget); save_state()
    end)
    text("Budget usage includes unconfirmed requests. Efficient ranking estimates listed-stat gain per gold, not actual DPS.", 54)
    action("Upgrade ranking: " .. session.options.upgrade_ranking, function(item)
        session.options.upgrade_ranking = session.options.upgrade_ranking == "efficient" and "cheapest" or "efficient"
        item.Text = "Upgrade ranking: " .. session.options.upgrade_ranking
        features.inventory_due = true; save_state()
    end)
    action("Retry gold upgrades", function()
        features.upgrade_blocked, features.inventory_due = false, true
        features.upgrade_note = "Gold upgrades: retry enabled"
    end)
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
    section("History")
    text("Rewards show observed XP, new drops, and net gold including spending. Last 20 results are retained across servers.", 54)
    action("Copy run history", function()
        if type(setclipboard) == "function" then
            local ok = pcall(function() setclipboard(Http:JSONEncode(session.metrics.history)) end)
            features.recovery = ok and "Run history copied" or "Could not copy history"
        end
    end)
    features.history_label = text("No completed runs recorded yet", 940)
    section("Diagnostics")
    text("F8 always pauses. These controls preserve deliberate pauses and goals. A repeated-hit correction uses isolated learned timing, not every recent cue.", 70)
    for _, name in ipairs({"Copy enemy details", "Copy lobby, gear and attack handlers", "Reset session counters / goals", "Close and stop"}) do y = features.ui_adopt(name, scroll, y) end
    features.route_label = text("Recording movement decisions...", 70)
    action("Copy stuck report", function()
        if type(setclipboard)=="function" then
            local ok, err = pcall(function() setclipboard(features.stuck_report()) end)
            features.recovery = ok and "Stuck report copied" or tostring(err)
        end
    end)
    action("Clear failed-route memory", function() features.failed_routes = {}; features.reset_steering=true end)
    features.damage_label = text("No health losses recorded yet", 560)
    scroll.CanvasSize = UDim2.fromOffset(0, y + 12)
    features.show_page(session.options.ui_page or "Overview")
    features.open_page = function(name)
        features.show_page(name or "Overview")
        panel.Visible = true
    end
    features.toggle_settings = function()
        if panel.Visible then panel.Visible = false else features.open_page(session.options.ui_page or "Overview") end
    end
    if features.main_scale then features.main_scale:Destroy() end
    local main_scale, panel_scale = Instance.new("UIScale", frame), Instance.new("UIScale", panel)
    features.main_scale=main_scale
    local camera = workspace.CurrentCamera
    if camera then
        local function resize()
            local viewport = camera.ViewportSize
            local scale = math.clamp(math.min((viewport.X - 32) / 800, (viewport.Y - 32) / 620), 0.6, 1)
            features.ui_scale = scale
            main_scale.Scale, panel_scale.Scale = scale, scale
            frame.Position = UDim2.fromOffset(math.clamp(frame.Position.X.Offset, 0, math.max(0, viewport.X - 460 * scale)), math.clamp(frame.Position.Y.Offset, 0, math.max(0, viewport.Y - (features.collapsed and 44 or 348) * scale)))
        end
        resize()
        connections[#connections + 1] = camera:GetPropertyChangedSignal("ViewportSize"):Connect(resize)
    end
end
function features.ensure_ui()
    if features.settings_panel and not features.ui_error then
        features.open_page(session.options.ui_page or "Overview")
        return true
    end
    local connection_start = #connections
    for _,connection in ipairs(features.settings_connections or {}) do connection:Disconnect() end
    features.settings_connections={}
    local function salvage_controls()
        for _, control in pairs(features.toolbar or {}) do
            control.Parent, control.Visible = frame, true
        end
    end
    salvage_controls()
    if features.settings_panel then features.settings_panel:Destroy() end
    local ok, err = pcall(features.build_settings)
    features.ui_error = not ok and tostring(err) or nil
    if not ok then
        salvage_controls()
        for index = #connections, connection_start + 1, -1 do connections[index]:Disconnect(); connections[index] = nil end
        if features.settings_panel then features.settings_panel:Destroy(); features.settings_panel = nil end
        features.toggle_settings = function() note = "Settings failed: " .. tostring(features.ui_error) .. "; click Repair settings" end
        note = "Settings failed: " .. tostring(err) .. "; click Repair settings"
        warn(note)
    else
        for index=connection_start+1,#connections do features.settings_connections[#features.settings_connections+1]=connections[index] end
        note = session.enabled and "Settings ready; automation active" or "Settings ready; automation paused"
    end
    return ok
end
-- Always available even if construction of a settings page fails.
local repair_ui = Instance.new("TextButton", frame)
repair_ui.Name, repair_ui.Text = "RepairSettings", "Repair settings"
repair_ui.Position, repair_ui.Size = UDim2.fromOffset(332, 8), UDim2.fromOffset(70, 26)
repair_ui.Text = "Repair"
repair_ui.ZIndex, repair_ui.TextColor3, repair_ui.TextSize = 3, Color3.new(1, 1, 1), 12
features.ui_style(repair_ui)
connections[#connections + 1] = repair_ui.Activated:Connect(function() features.ensure_ui() end)
features.ensure_ui()
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
function features.indicator(part, native_payload)
    if not part:IsA("BasePart") then return end
    if part.Name == "fire" or part.Name == "flame" then
        local parent = part.Parent
        while parent and parent ~= workspace do
            if features.flame_folders and features.flame_folders[parent.Name] == part.Name then
                features.indicators[part] = true
                features.flame_parts[parent.Name] = features.flame_parts[parent.Name] or {}
                features.flame_parts[parent.Name][part] = true
                return
            end
            parent = parent.Parent
        end
    end
    if not part.Name:lower():find("precast", 1, true) then return end
    local templates = RS:FindFirstChild("enemyProjectiles")
    local node, matched = part.Parent, false
    local direct = templates and templates:FindFirstChild(part.Name, true)
    if direct and direct:IsA("BasePart") then
        local parent = direct.Parent
        while parent and parent ~= templates and parent:IsA("Folder") do parent = parent.Parent end
        matched = parent == templates
    end
    while node and node ~= workspace do
        if excluded and excluded[node.Name:lower()] then return end
        if node:IsA("Model") and Players:GetPlayerFromCharacter(node) then return end
        local template = templates and templates:FindFirstChild(node.Name, true)
        if template and template:IsA("Model") then matched = true end
        node = node.Parent
    end
    if node == workspace and (matched or native_payload) then features.indicators[part] = true end
end
for _, part in ipairs(workspace:GetDescendants()) do features.indicator(part) end
connections[#connections + 1] = workspace.DescendantAdded:Connect(function(part) features.indicator(part) end)
task.spawn(function()
    local module = RS:FindFirstChild("timeSync")
    if module and module:IsA("ModuleScript") then
        local ok, value = pcall(require, module)
        if ok and type(value) == "table" and type(value.GetTime) == "function" then features.clock = value end
    end
end)
function features.server_time()
    if not features.clock then return end
    local ok, value = pcall(features.clock.GetTime, features.clock)
    if ok and type(value) == "number" and value == value then return value end
end
function features.add_area(frame, size, duration, part)
    if typeof(frame) ~= "CFrame" or typeof(size) ~= "Vector3" or duration <= 0 then return end
    features.hazards[#features.hazards + 1] = {frame = frame, size = size, expires = os.clock() + math.min(duration, 30), part = part,
        relative = part and part.CFrame:ToObjectSpace(frame)}
    while #features.hazards > 64 do table.remove(features.hazards, 1) end
end
function features.until_server(deadline, extra)
    local now = features.server_time()
    if now and type(deadline) == "number" and deadline >= now - 0.5 and deadline - now <= 30 then
        return math.max(0.05, deadline - now + (extra or 0))
    end
end
function features.template_area(name, frame, duration)
    local templates = RS:FindFirstChild("enemyProjectiles")
    local template = templates and templates:FindFirstChild(name, true)
    local precast = template and template:FindFirstChild("precast", true)
    if template and template:IsA("Model") and template.PrimaryPart and precast and precast:IsA("BasePart") then
        features.add_area(frame * template.PrimaryPart.CFrame:ToObjectSpace(precast.CFrame), precast.Size, duration)
    end
end
function features.corridor(payload, width)
    if type(payload) ~= "table" or typeof(payload[5]) ~= "CFrame" then return end
    local distance, duration = tonumber(payload[1]), features.until_server(payload[4], 0.35)
    if not distance or distance <= 0 or distance > 1500 or not duration then return end
    local frame = payload[5]
    features.add_area(frame + frame.LookVector * (distance / 2 - 5), Vector3.new(width, 12, distance + 10), duration)
end
function features.gaze_target()
    local gaze = features.look_away
    if not gaze then return end
    local gui = player:FindFirstChildOfClass("PlayerGui")
    local visible = gui and gui:FindFirstChild("firstBossLookAwayGui")
    if visible then gaze.gui_seen = true end
    if not gaze.part.Parent or os.clock() >= gaze.expires or (gaze.gui_seen and not visible)
        or (not gaze.gui_seen and os.clock() - gaze.started > 0.75 and not features.clock) then
        features.look_away = nil
        return
    end
    return gaze.part
end
function features.color_zone(color)
    if type(color) ~= "string" or color == "" then return end
    local folder = workspace:FindFirstChild("thirdBossSafeZones")
    if not folder then return end
    color = color:lower():gsub("%W", "")
    if color == "" then return end
    local chosen
    for _, node in ipairs(folder:GetDescendants()) do
        local name = node.Name:lower():gsub("%W", "")
        local label = node:GetAttribute("color") or node:GetAttribute("Color")
        if name == color or name == "safezone" .. color or name:sub(1, #color + 4) == color .. "zone"
            or name:sub(1, #color + 8) == color .. "safezone" or (type(label) == "string" and label:lower() == color) then
            local part = node:IsA("BasePart") and node or node:FindFirstChild("hitBox", true)
                or (node:IsA("Model") and node.PrimaryPart)
            if part and part:IsA("BasePart") then
                if chosen and chosen ~= part then return nil end -- Require one unambiguous native label.
                chosen = part
            end
        end
    end
    return chosen
end
function features.signal(remote, kind, payload)
    if not session.enabled then return end
    if type(kind) == "string" then
        features.recent_cues[#features.recent_cues + 1] = {key = remote .. "/" .. kind, at = os.clock()}
        if #features.recent_cues > 24 then table.remove(features.recent_cues, 1) end
    end
    features.signal_counts = features.signal_counts or {}
    if type(kind) == "string" and #kind < 160 then
        local key = remote .. "/" .. kind
        if features.signal_counts[key] or (features.signal_unique or 0) < 256 then
            if not features.signal_counts[key] then features.signal_unique = (features.signal_unique or 0) + 1 end
            features.signal_counts[key] = math.min((features.signal_counts[key] or 0) + 1, 1000000)
        end
    end
    local flames = ({sanadaClientEvents = {"sanadaFireParts", "fire"}, golemClientEvents = {"golemFlames", "flame"},
        miyamotoClientEvents = {"miyamotoFlames", "flame"}})[remote]
    if flames and (kind == "showFire" or kind == "hideFire") then
        features.flame_folders, features.flame_parts = features.flame_folders or {}, features.flame_parts or {}
        if kind == "showFire" then
            features.flame_folders[flames[1]] = flames[2]
            local folder = workspace:FindFirstChild(flames[1])
            if folder then for _, part in ipairs(folder:GetDescendants()) do features.indicator(part) end end
        else
            features.flame_folders[flames[1]] = nil
            for part in pairs(features.flame_parts[flames[1]] or {}) do features.indicators[part] = nil end
            features.flame_parts[flames[1]] = nil
        end
    end
    local function register(instance)
        if typeof(instance) ~= "Instance" or not instance.GetDescendants then return end
        features.indicator(instance, true)
        for _, part in ipairs(instance:GetDescendants()) do features.indicator(part, true) end
    end
    if typeof(payload) == "Instance" then register(payload)
    elseif type(payload) == "table" then
        local count = 0
        for _, instance in pairs(payload) do count = count + 1; if count > 16 then break end; register(instance) end
    end
    if remote == "bossSpecficEvents" and kind == "Second Boss Show Safe Spot" and typeof(payload) == "Instance" then
        local part = payload:FindFirstChild("hitBox")
        if part and part:IsA("BasePart") then features.safe_zone = {part = part, expires = os.clock() + 6.6} end
    elseif remote == "volcanicBossSpecficEvents" and kind == "First Boss Sky Shot" and typeof(payload) == "Vector3" then
        features.template_area("firstBossSkyShot", CFrame.new(payload), 3.5)
    elseif remote == "bossSpecficEvents" and kind == "Minion Explosion" and typeof(payload) == "CFrame" then
        features.add_area(payload, Vector3.new(40, 40, 40), 0.5)
    elseif remote == "volcanicBossSpecficEvents" then
        if kind == "Second Boss Rock Fall" and typeof(payload) == "CFrame" then
            features.add_area(payload, Vector3.new(42, 42, 42), 1.9)
        elseif kind == "Artillery Mob Shot" and type(payload) == "table" and typeof(payload[2]) == "CFrame" then
            features.add_area(payload[2], Vector3.new(15, 15, 15), 1.25)
        elseif kind == "Third Boss Link Players" and type(payload) == "table" then
            local other = player.Character == payload[1] and payload[2] or (player.Character == payload[2] and payload[1])
            local part = typeof(other) == "Instance" and other:FindFirstChild("HumanoidRootPart")
            if part and part:IsA("BasePart") then features.safe_zone = {part = part, expires = os.clock() + 5, radius = 8} end
        end
    elseif remote == "northernBossSpecficEvents" then
        if kind == "First Boss Big Spike" then features.corridor(payload, 40)
        elseif kind == "First Boss Seeking Spike" or kind == "First Boss Criss Cross Projectile"
            or kind == "Second Boss Moving Beam" or kind == "Third Boss Sideways Missile" then
            local names = {["First Boss Seeking Spike"] = "firstBossSeekingSpikes", ["First Boss Criss Cross Projectile"] = "firstBossCrissCross",
                ["Second Boss Moving Beam"] = "secondBossMovingBeam", ["Third Boss Sideways Missile"] = "thirdBossMissile"}
            local templates = RS:FindFirstChild("enemyProjectiles")
            local template = templates and templates:FindFirstChild(names[kind])
            local size = template and (template:IsA("Model") and template:GetExtentsSize() or (template:IsA("BasePart") and template.Size))
            if size then features.corridor(payload, math.max(6, math.sqrt(size.X^2 + size.Y^2 + size.Z^2))) end
        elseif kind == "Second Boss Big Hitting Ground Spikes" and type(payload) == "table" and typeof(payload[2]) == "CFrame" then
            local names = {small = "smallIceSpikes", medium = "mediumIceSpikes", large = "largeIceSpikes"}
            local duration = features.until_server(payload[3], 0.5)
            if names[payload[1]] and duration then features.template_area(names[payload[1]], payload[2], duration) end
        end
    elseif remote == "gildedBossSpecficEvents" then
        if kind == "Second Boss Big Circle" and type(payload) == "table" and typeof(payload[1]) == "CFrame" then
            local duration = features.until_server(payload[3], 0.65)
            if duration then features.add_area(payload[1], Vector3.new(100, 100, 100), duration) end
        elseif kind == "First Boss Blinding Blast" then
            local part = workspace:FindFirstChild("firstBossMiddlePart")
            if part and part:IsA("BasePart") then
                features.look_away = {part = part, started = os.clock(), expires = os.clock() + (features.until_server(payload, 0.15) or 10)}
            end
        elseif kind == "Third Boss Show Safe Zones" and type(payload) == "table" then
            for _, entry in pairs(payload) do
                if type(entry) == "table" and entry.char == player.Character then
                    local part = features.color_zone(entry.color)
                    if part then features.safe_zone = {part = part, expires = os.clock() + 60, channel = "gilded"}
                    else features.mechanic_note = "Assigned safe color could not be resolved: " .. tostring(entry.color) end
                end
            end
        elseif kind == "Third Boss Hide Safe Zones" and features.safe_zone and features.safe_zone.channel == "gilded" then
            features.safe_zone.expires = os.clock() + 1.1
        end
    elseif remote == "enchantedBossSpecficEvents" and kind == "Third Boss One Shot Beam"
        and type(payload) == "table" and typeof(payload[1]) == "CFrame" then
        local duration = features.until_server(payload[2], 0.7)
        if duration then features.add_area(payload[1], Vector3.new(84, 20, 84), duration) end
    elseif remote == "mapSpecificEvent" then
        if kind == "ROTG2 Rock Fall" and typeof(payload) == "CFrame" then
            features.add_area(payload, Vector3.new(45, 45, 45), 1.6)
        elseif kind == "ROTG2 Boss Arm Glow" and typeof(payload) == "Instance" then
            local part = enemy_root(payload)
            if part then features.add_area(part.CFrame + part.CFrame.LookVector * 8 - Vector3.new(0, 4, 0), Vector3.new(60, 60, 60), 1.6, part) end
        end
    elseif remote == "steampunkBossSpecficEvents" then
        if kind == "Second Boss Aura" and typeof(payload) == "CFrame" then
            features.add_area(payload, Vector3.new(60, 12, 60), 4.8)
        elseif kind == "Second Boss Pulse Wave" then
            features.jump_until = os.clock() + 0.35
        end
    end
end
function features.hazard_risk(position, now)
    local risk = 0
    local function rectangle(frame, size)
        local local_point = frame:PointToObjectSpace(position)
        local vertical = frame:VectorToObjectSpace(Vector3.new(0, -1, 0))
        risk = math.max(risk, Policy.box_risk(local_point, vertical, size, 3))
    end
    for _, hazard in ipairs(features.hazards) do
        if now <= hazard.expires and (not hazard.part or (hazard.part.Parent and hazard.part:IsDescendantOf(workspace))) then
            rectangle(hazard.part and (hazard.part.CFrame * hazard.relative) or hazard.frame, hazard.size)
        end
    end
    for part in pairs(features.indicators) do
        if part.Parent and part:IsDescendantOf(workspace) and part.Transparency < 0.95 then rectangle(part.CFrame, part.Size) end
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
                features.run_started = features.run_started or os.time()
                features.ensure_run()
            end
            previous_started = started and started.Value == true or false
            local character = player.Character
            local humanoid = character and character:FindFirstChildOfClass("Humanoid")
            if humanoid and features.death_watch ~= humanoid then
                features.death_watch = humanoid
                connections[#connections + 1] = humanoid.Died:Connect(function()
                    if session.enabled then
                        session.metrics.deaths = session.metrics.deaths + 1
                        if features.run_stats and not features.run_stats.result then features.run_stats.deaths = features.run_stats.deaths + 1 end
                        save_state()
                    end
                end)
            end
            local indicators = 0
            for part in pairs(features.indicators) do
                if not part.Parent or not part:IsDescendantOf(workspace) then features.indicators[part] = nil
                elseif part.Transparency < 0.95 then indicators = indicators + 1 end
            end
            for index = #features.hazards, 1, -1 do
                if now > features.hazards[index].expires then table.remove(features.hazards, index) end
            end
            features.telegraphs = "Enemy indicators: " .. indicators .. "; signal areas: " .. #features.hazards
                .. "; cues seen: " .. (features.signal_unique or 0)
                .. (features.safe_part() and "; moving to safe zone" or "")
                .. (features.mechanic_note and ("; " .. features.mechanic_note) or "")
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
            features.combat_tick()
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
            local correction = session.options and session.options.boss_corrections and pattern and math.max(0, (pattern.count or 0) - 3) or 0
            if Policy.window(pattern, elapsed, math.min(0.4, correction * 0.04)) then
                local current = part.CFrame:PointToObjectSpace(position)
                local original = attack.origin:PointToObjectSpace(position)
                for _, sample in ipairs(pattern.samples) do
                    local current_gap = (current.X - sample.x)^2 + (current.Z - sample.z)^2
                    local original_gap = (original.X - sample.x)^2 + (original.Z - sample.z)^2
                    local gap = math.min(current_gap, original_gap)
                    local radius_squared = (6 + math.min(2.5, correction * 0.2))^2
                    if gap < radius_squared then risk = math.max(risk, 1 - gap / radius_squared) end
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
    local previous, previous_max = humanoid.Health, humanoid.MaxHealth
    health_connection = humanoid.HealthChanged:Connect(function(health)
        local amount, maximum = math.max(0, previous - health), humanoid.MaxHealth
        local damaged = amount > 0 and previous_max == maximum
        previous, previous_max = health, maximum
        if damaged then features.damage_event(amount, maximum, health) end
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
features.remote_watched = setmetatable({}, {__mode = "k"})
function features.connect_signal(remote)
    if features.remote_watched[remote] then return end
    local name = remote.Name:lower()
    if remote:IsA("RemoteEvent") and (name:find("specficevents", 1, true)
        or name:find("specificevents", 1, true) or name:find("clientevents", 1, true) or name == "mapspecificevent") then
        features.remote_watched[remote] = true
        connections[#connections + 1] = remote.OnClientEvent:Connect(function(kind, payload)
            local ok, err = pcall(features.signal, remote.Name, kind, payload)
            if not ok then features.mechanic_note = "Dodge cue error: " .. tostring(err) end
            if #enemies == 1 and target and kind ~= "Shake Screens" and kind ~= "hideFire" and kind ~= "endFireCyclone" then
                local id = (type(kind) == "string" or type(kind) == "number") and tostring(kind) or "signal"
                begin_attack(target, remote.Name .. "/" .. id, 3)
            end
        end)
    end
end
for _, remote in ipairs(remotes:GetChildren()) do features.connect_signal(remote) end
connections[#connections + 1] = remotes.ChildAdded:Connect(features.connect_signal)
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
            local override_aoe = tonumber(profile.aoe_radius) or 0
            local buff = duration > 0 or Policy.is_buff(tool.Name, tool:FindFirstChild("buffPower") ~= nil)
            skills[#skills + 1] = {tool = tool, slot = slot.Value, event = event,
                cooldown = cooldown.Value, length = number("cooldownLength", 1),
                damage = number("damage", 1), buff = buff, buff_duration = duration,
                priority = math.clamp(tonumber(profile.priority) or 0, -5, 5),
                aoe_radius = math.clamp(override_aoe > 0 and override_aoe or number("radius", 0), 0, 80),
                range = override_range > 0 and override_range or (buff and (config.attack_range + 6) or number("range", tool:FindFirstChild("fireballShootEvent") and 60 or 12)),
                next_ready = previous.next_ready, last_used = previous.last_used}
        end
    end
    return skills
end

local function body_radius(part)
    return part.Size and math.clamp(math.max(part.Size.X, part.Size.Z) / 2, 1, 8) or 1
end
local function wall_heading(root, desired, normal, params, now)
    normal = flat(normal)
    if normal.Magnitude < 0.01 then return end
    normal = normal.Unit
    local tangent = Vector3.new(-normal.Z, 0, normal.X)
    local previous = features.wall_route
    local stride = math.clamp((controlled and controlled.WalkSpeed or 16) * 0.18, 1.5, 3)
    local origin, down = root.Position + Vector3.new(0, 3, 0), Vector3.new(0, -30, 0)
    local floor = workspace:Raycast(origin, down, params)
    local best, best_score
    for index = 0, 17 do
        local candidate
        if index < 2 then
            candidate = (tangent * (index == 0 and 1 or -1) + normal * 0.18).Unit
        else
            local angle = (index - 2) * math.pi / 8
            candidate = Vector3.new(math.cos(angle), 0, math.sin(angle))
        end
        local side = Vector3.new(-candidate.Z, 0, candidate.X) * 0.9
        local travel = candidate * stride
        local valid = candidate:Dot(normal) >= -0.05
            and not workspace:Raycast(root.Position, travel, params)
            and not workspace:Raycast(root.Position + side, travel, params)
            and not workspace:Raycast(root.Position - side, travel, params)
            and (not floor or workspace:Raycast(origin + travel, down, params))
        if valid then
            local risk = math.max(pattern_risk(root.Position + travel * 0.5, now + 0.18),
                pattern_risk(root.Position + travel, now + 0.35))
            if risk <= math.max(0.4, pattern_risk(root.Position, now + 0.35)) then
                local score = math.abs(candidate:Dot(tangent)) * 3 + candidate:Dot(normal) * 0.6
                    + candidate:Dot(desired) * 0.5 - risk * 100
                if features.route_penalty then score = score - features.route_penalty(root.Position, candidate, now) end
                if previous and previous.until_time > now then score = score + candidate:Dot(previous.direction) * 3 end
                score = score + candidate:Dot(tangent) * (features.orbit_sign or 1) * 0.05
                if not best_score or score > best_score then best, best_score = candidate, score end
            end
        end
    end
    if best then
        local deadline = previous and previous.until_time > now and previous.until_time or now + 1.1
        features.wall_route = {direction = best, normal = normal, until_time = deadline}
        return best * 0.7
    end
end
local function tactical_direction(root, part, params, now)
    local desired = config.spacing + body_radius(part) - 1
    if session.options and session.options.adaptive_spacing and features.adaptive then desired = desired + features.adaptive.offset end
    local stance = session.options and session.options.profile or "Balanced"
    desired = desired + (stance == "Conservative" and 3 or (stance == "Aggressive" and -1 or 0))
    if controlled and controlled.MaxHealth and controlled.MaxHealth > 0
        and controlled.Health / controlled.MaxHealth < (stance == "Conservative" and 0.5 or 0.35) then desired = desired + 5 end
    local step = math.clamp((controlled and controlled.WalkSpeed or 16) * 0.35, 3, 6)
    local origin = root.Position + Vector3.new(0, 3, 0)
    local down = Vector3.new(0, -30, 0)
    local current_floor = workspace:Raycast(origin, down, params)
    local nearby, center = {}, Vector3.zero
    for _, model in ipairs(enemies) do
        local enemy = enemy_root(model)
        if enemy and flat(enemy.Position - root.Position).Magnitude < 36
            and flat(enemy.Position - part.Position).Magnitude < 22
            and math.abs(enemy.Position.Y - root.Position.Y) < math.max(10, enemy.Size.Y / 2 + 6)
            and clear_path(root, enemy.Position, params) then
            local motion = features.motion and features.motion[model]
            local velocity = motion and motion.velocity or flat(enemy.AssemblyLinearVelocity or Vector3.zero)
            if velocity.Magnitude > 40 then velocity = velocity.Unit * 40 end
            nearby[#nearby + 1] = {part = enemy, velocity = velocity, radius = body_radius(enemy)}
        end
    end
    table.sort(nearby, function(a, b) return (a.part.Position - root.Position).Magnitude < (b.part.Position - root.Position).Magnitude end)
    while #nearby > 12 do table.remove(nearby) end
    for _, enemy in ipairs(nearby) do center = center + enemy.part.Position + enemy.velocity * 0.25 end
    center = #nearby > 0 and center / #nearby or part.Position
    local crowded, extent = #nearby > 1, 0
    for _, enemy in ipairs(nearby) do
        extent = math.max(extent, flat(enemy.part.Position + enemy.velocity * 0.25 - center).Magnitude + enemy.radius)
    end
    local away = flat(root.Position - center)
    away = away.Magnitude > 0.01 and away.Unit or Vector3.new(1, 0, 0)
    local tangent = Vector3.new(-away.Z, 0, away.X) * (features.orbit_sign or 1)
    local speed = math.max(controlled and controlled.WalkSpeed or 16, 1)
    local best, best_score, moving_choices = nil, nil, 0
    local moving_best, moving_score, moving_risk, use_short
    for index = 0, 48 do
        if index == 24 then use_short = moving_choices == 0 end
        if index < 24 or index == 48 or use_short then
        local angle = (index % 24) * math.pi / 12
        local scale = index >= 24 and index < 48 and 0.3 or 1
        local direction = index == 48 and Vector3.zero or Vector3.new(math.cos(angle), 0, math.sin(angle)) * scale
        local position = root.Position + direction * step
        local side = direction.Magnitude > 0.01 and Vector3.new(-direction.Z, 0, direction.X).Unit * 1.1 or Vector3.zero
        local valid = direction.Magnitude < 0.01
            or (not workspace:Raycast(root.Position, direction * step, params)
            and not workspace:Raycast(root.Position + side, direction * step, params)
            and not workspace:Raycast(root.Position - side, direction * step, params)
            and (not current_floor or workspace:Raycast(origin + direction * step, down, params)))
        if valid then
            if direction.Magnitude > 0.01 then moving_choices = moving_choices + 1 end
            local score = -math.abs(flat(position - part.Position).Magnitude - desired) * (crowded and 0.2 or 0.7)
            if crowded then
                local gap = flat(position - center).Magnitude - extent
                local spacing = math.max(5, desired - body_radius(part))
                score = score - math.abs(gap - spacing) * 0.55 - math.max(0, spacing - gap)^2 * 0.8
            end
            score = score + tangent:Dot(direction) * 0.9
            local peak_risk = 0
            -- Score the route at several future instants, not just its destination.
            for _, horizon in ipairs({0.18, 0.4, 0.65}) do
                local future_position = root.Position + direction * speed * horizon
                local predicted_risk = pattern_risk(future_position, now + horizon)
                peak_risk = math.max(peak_risk, predicted_risk)
                score = score - predicted_risk * (30 + horizon * 75)
                for _, record in ipairs(nearby) do
                    local enemy = record.part
                    local offset = flat(future_position - enemy.Position - record.velocity * horizon)
                    local gap = offset.Magnitude - record.radius
                    local minimum = crowded and math.max(5, config.spacing - 1.5) or 5
                    if gap < minimum then score = score - (minimum - gap)^2 * 5 end
                    local facing = flat(enemy.CFrame.LookVector)
                    if gap < 13 and offset.Magnitude > 0.01 and facing.Magnitude > 0.01 then
                        local front = facing.Unit:Dot(offset.Unit)
                        if front > 0.25 then score = score - (13 - gap) * (front - 0.25) / 3 end
                    end
                end
            end
            if features.route_penalty then score = score - features.route_penalty(root.Position, direction, now) end
            score = score + steering:Dot(direction) * 0.3
            if index == 48 then score = score + 0.15 end
            if not best_score or score > best_score then best, best_score = direction, score end
            if direction.Magnitude > 0.01 and (not moving_score or score > moving_score) then
                moving_best, moving_score, moving_risk = direction, score, peak_risk
            end
        end
        end
    end
    local escaping = false
    if best and best.Magnitude < 0.01 then
        features.hold_since = features.hold_since or now
        if moving_best and now - features.hold_since >= 1.25 and flat(root.Position - part.Position).Magnitude < desired + 4
            and moving_risk <= math.max(0.55, pattern_risk(root.Position, now + 0.35)) then
            best, escaping = moving_best, true
        end
    else features.hold_since = nil end
    local reason = pattern_risk(root.Position, now + 0.35) >= 0.8 and "Avoiding learned attack"
        or (best and best.Magnitude < 0.01 and "Holding safe spacing"
        or (crowded and ("Circling crowd: " .. #nearby .. " enemies") or "Seeking safer spacing"))
    if escaping then reason = "Escaping spacing standstill" end
    if best and best:Dot(tangent) < -0.5 then features.orbit_sign = -(features.orbit_sign or 1) end
    if moving_choices == 0 then reason = "No safe movement direction: walls / ledges" end
    return best or Vector3.zero, reason
end

function features.auto_swing(character, root)
    if not session.enabled or session.options.auto_swing==false or lobby_place or features.outcome or features.restore_pending
        or pending_cast or os.clock()-last_swing<0.6 then return end
    local peaceful=player:FindFirstChild("peaceful")
    local started=workspace:FindFirstChild("dungeonStarted")
    local busy=character:FindFirstChild("busyCasting")
    if (peaceful and peaceful.Value) or not started or not started.Value or (busy and busy.Value) then return end
    local limit=session.options.profile=="Conservative" and 0.4 or (session.options.profile=="Aggressive" and 0.8 or 0.6)
    if pattern_risk(root.Position,os.clock()+0.25)>=limit or features.gaze_target() then return end
    local safe=features.safe_part()
    if safe then return end
    local nearest,gap
    for _,model in ipairs(enemies) do
        local part=enemy_root(model)
        if part and (not features.role or features.role(model)~="ignore") then
            local distance=(part.Position-root.Position).Magnitude-body_radius(part)+1
            if distance<=config.attack_range and (not gap or distance<gap) and clear_path(root,part.Position,ray_params(character)) then nearest,gap=part,distance end
        end
    end
    if not nearest then features.swing_note="Melee: no enemy in range";return end
    local offset=flat(nearest.Position-root.Position)
    local facing=flat(root.CFrame.LookVector)
    if offset.Magnitude>0.1 and facing.Magnitude>0.1 and facing.Unit:Dot(offset.Unit)<0.7 then
        features.aim_point={position=nearest.Position,model=target,expires=os.clock()+0.15}
        features.swing_note="Melee: facing nearby enemy";return
    end
    for _,item in ipairs(character:GetChildren()) do
        if item:IsA("Accessory") and item:FindFirstChild("Weapon") then
            local event=item:FindFirstChildOfClass("RemoteEvent")
            local used=remotes:FindFirstChild("weaponUsed")
            if event and used and used:IsA("RemoteEvent") then
                last_swing=os.clock()
                event:FireServer();used:FireServer()
                session.metrics.swings=(session.metrics.swings or 0)+1
                features.swing_note="Melee: swinging at nearby enemy";return
            end
        end
    end
    features.swing_note="Melee: waiting for equipped weapon"
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
                features.auto_swing(character, root)
                target = find_target(root)
                local part = target and enemy_root(target)
                if not part then
                    note = #enemies > 0 and ("No eligible target among " .. #enemies .. " enemies; check role overrides")
                        or "Detected 0 live enemies. If visible, click Copy enemy details."
                    ability_note = "Abilities: waiting for target"
                    return
                end
                local distance = math.max(0, (part.Position - root.Position).Magnitude - body_radius(part) + 1)
                note = "Detected " .. #enemies .. " | " .. target.Name .. " | " .. math.floor(distance) .. " studs"
                if distance > config.cast_range then return end
                if features.restore_pending then ability_note = "Abilities: waiting for gear restoration"; return end
                local busy = character:FindFirstChild("busyCasting")
                if not busy or busy.Value then ability_note = "Abilities: cast animation active"; return end
                if pending_cast then ability_note = "Abilities: waiting for cast start"; return end
                local now = os.clock()
                local danger = pattern_risk(root.Position, now + 0.25)
                local safe = features.safe_part()
                local safe_radius = safe and (features.safe_zone.radius or math.max(1, math.min(safe.Size.X, safe.Size.Z) / 2 - 2))
                if safe and flat(root.Position - safe.Position).Magnitude > safe_radius then danger = 1 end
                if features.gaze_target() then danger = 1 end
                local stance = session.options.boss_profiles[target.Name] or session.options.profile
                local danger_limit = stance == "Conservative" and 0.4 or (stance == "Aggressive" and 0.8 or 0.6)
                local skills = ability_candidates(character, now)
                for _, candidate in ipairs(skills) do
                    if candidate.aoe_radius > 0 then
                        candidate.targets = 0
                        for _, model in ipairs(enemies) do
                            local root_part = enemy_root(model)
                            if root_part and flat(root_part.Position - part.Position).Magnitude <= candidate.aoe_radius then candidate.targets = candidate.targets + 1 end
                        end
                    end
                end
                local skill, decision = Policy.choose_combo(skills, now, distance, danger, danger_limit,
                    {combo = session.options.ability_combos, aoe = session.options.aoe_priority})
                if skill then
                    local motion = features.motion[target]
                    local velocity = motion and motion.velocity or Vector3.zero
                    local profile = session.options.abilities[skill.tool.Name] or {}
                    local lead = session.options.predictive_aim and math.clamp(tonumber(profile.aim_lead) or 0.15, 0, 0.6) or 0
                    local predicted = Policy.predict_aim(part.Position, velocity, lead)
                    if not clear_path(root, predicted, ray_params(character)) then predicted = part.Position end
                    features.aim_point = {position = predicted, expires = now + 0.2, model = target}
                    local incoming = false
                    if skill.aoe_radius > 0 then
                        for _, model in ipairs(enemies) do
                            local other, movement = enemy_root(model), features.motion[model]
                            if model ~= target and other and movement then
                                local present = flat(other.Position - part.Position).Magnitude
                                local future = flat(other.Position + movement.velocity * 0.6 - predicted).Magnitude
                                if present > skill.aoe_radius and future <= skill.aoe_radius then incoming = true end
                            end
                        end
                    end
                    if not skill.buff and skill.aoe_radius > 0 and Policy.aoe_hold(features.aoe_wait, skill.tool, now,
                        skill.targets or 1, incoming, session.options.aoe_wait) then
                        ability_note = "Abilities: grouping AoE (maximum 0.65s)"; return
                    end
                    local offset = flat(predicted - root.Position)
                    local facing = flat(root.CFrame.LookVector)
                    if not skill.buff and offset.Magnitude > 0.01 and facing.Magnitude > 0.01
                        and facing.Unit:Dot(offset.Unit) < 0.85 then
                        ability_note = "Abilities: aligning with target"
                        return
                    end
                    local attempt = {next_ready = now + 0.5, last_used = skill.last_used}
                    attempts[skill.tool] = attempt
                    pending_cast = attempt
                    features.aoe_wait[skill.tool] = nil
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
                ability_note = "Abilities: " .. decision
                if danger >= danger_limit then return end
            end)
            if not ok then note = "Combat error: " .. tostring(err) end
        end
        if session.alive then
            status.Text = features.ui_error and ("Settings error: " .. features.ui_error .. "\nClick Repair settings")
                or session.exporting and "Exporting client controls..."
                or session.options.compact_hud and ("Lv " .. tostring(features.level() or "?") .. " | " .. (session.metrics.selected_tier or "Selecting dungeon")
                    .. "\nTarget: " .. (target and target.Name or "none") .. "\n" .. movement_note .. "\n" .. (features.swing_note or features.recovery))
                or (note .. (lobby_place and "" or ("\n" .. movement_note .. "\n" .. ability_note))
                .. "\n" .. learning_note .. "\n" .. stat_note .. "\n" .. (features.swing_note or "Melee: ready"))
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
local function movement_frame(dt, fallback)
    if not session.alive then return end
    if not fallback then features.last_render_tick = os.clock() end
    if features.reset_steering then
        planned, steering, decision_time = Vector3.zero, Vector3.zero, 0
        features.reset_steering = nil
    end
    local ok, err = pcall(function()
        local character, humanoid, root = character_parts()
        local part, navigation_key = features.navigation_target()
        local peaceful = player:FindFirstChild("peaceful")
        if not session.enabled or features.outcome or features.restore_pending or not root or not part or (peaceful and peaceful.Value) then
            features.watchdog, features.escape_until, features.wall_route, features.movement_blocked = {}, nil, nil, nil
            movement_note = features.restore_pending and "Restoring gear before combat" or (not session.enabled and "Movement paused"
                or (not root and "Waiting for character"
                or ((peaceful and peaceful.Value) and "Movement waiting for dungeon" or "Waiting for target")))
            release_movement()
            return
        end
        if root.Anchored or humanoid.WalkSpeed <= 0 or humanoid.PlatformStand or humanoid.Sit then
            features.watchdog, features.escape_until, features.wall_route, features.movement_blocked = {}, nil, nil, nil
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
        if features.jump_until and os.clock() < features.jump_until and humanoid.FloorMaterial ~= Enum.Material.Air then humanoid.Jump = true end
        local delta = flat(part.Position - root.Position)
        features.watchdog = features.watchdog or {}
        local safe_hold = features.safe_part()
        local safe_radius_now = safe_hold and (features.safe_zone.radius or math.max(1, math.min(safe_hold.Size.X, safe_hold.Size.Z) / 2 - 2))
        local holding = safe_hold and delta.Magnitude <= safe_radius_now
        local stage = Policy.watchdog(features.watchdog, os.clock(), root.Position,
            (planned.Magnitude > 0.05 or steering.Magnitude > 0.05 or features.movement_blocked) and not holding)
        if stage then
            if features.remember_route then features.remember_route(root.Position, planned.Magnitude > 0.05 and planned or delta, navigation_key) end
            features.wall_route = nil
            session.metrics.recoveries = (session.metrics.recoveries or 0) + 1
            waypoints, path_target, last_path = nil, nil, 0
            features.orbit_sign = -(features.orbit_sign or 1)
            features.escape_until = os.clock() + 1.2
            features.recovery = "Movement recovery " .. stage .. ": " .. (stage == 1 and "alternate direction" or (stage == 2 and "rebuild route" or "switch target"))
            if stage >= 2 and humanoid.FloorMaterial ~= Enum.Material.Air then humanoid.Jump = true end
            if stage == 3 and target and not safe_hold then
                features.blocked_targets[target] = os.clock() + 8
                target = nil
                features.watchdog = {}
            end
        end
        if os.clock() >= decision_time then
            decision_time = os.clock() + 0.08
            local params = ray_params(character)
            local distance = delta.Magnitude
            local toward = distance > 0.01 and delta.Unit or Vector3.new(0, 0, -1)
            local direction = Vector3.zero
            local reason = path_note
            local safe = features.safe_part()
            features.movement_blocked = false
            local safe_radius = safe and (features.safe_zone.radius or math.max(1, math.min(safe.Size.X, safe.Size.Z) / 2 - 2))
            if safe and distance <= safe_radius then
                direction, reason = Vector3.zero, "Inside boss safe zone"
            elseif safe and clear_path(root, safe.Position, params) then
                direction, reason = toward, "Moving to boss safe zone"
            elseif (distance < 24 or pattern_risk(root.Position, os.clock() + 0.35) >= 0.6
                or pattern_risk(root.Position + toward * math.min(distance, humanoid.WalkSpeed * 0.6), os.clock() + 0.6) >= 0.6)
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
            if not safe and direction.Magnitude>0.05 and features.route_penalty
                and features.route_penalty(root.Position,direction,os.clock())>=5 then
                local alternate=wall_heading(root,toward,-direction.Unit,params,os.clock())
                if alternate then direction,reason=alternate,"Avoiding a recent failed approach" end
            end
            if features.escape_until and os.clock() < features.escape_until and not safe then
                local best, risk
                for index = 0, 11 do
                    local angle = index * math.pi / 6
                    local candidate = Vector3.new(math.cos(angle), 0, math.sin(angle))
                    local destination = root.Position + candidate * 3
                    local origin = root.Position + Vector3.new(0, 3, 0)
                    local floor = workspace:Raycast(origin, Vector3.new(0, -30, 0), params)
                    if clear_path(root, destination, params) and (not floor or workspace:Raycast(origin + candidate * 3, Vector3.new(0, -30, 0), params)) then
                        local danger = pattern_risk(destination, os.clock() + 0.35)
                        local score = danger * 100 + candidate:Dot(steering) * 2
                            + (features.route_penalty and features.route_penalty(root.Position, candidate, os.clock()) or 0)
                        if not risk or score < risk then best, risk = candidate, score end
                    end
                end
                if best and pattern_risk(root.Position + best * 3, os.clock() + 0.35) <= math.max(0.4, pattern_risk(root.Position, os.clock() + 0.35)) then
                    direction, reason = best * 0.6, features.recovery
                end
            end
            if not safe and features.wall_route and features.wall_route.until_time > os.clock() then
                local slide = wall_heading(root, toward, features.wall_route.normal, params, os.clock())
                if slide then direction, reason = slide, "Following wall to clear obstruction" end
            end
            if direction.Magnitude > 1 then direction = direction.Unit end
            if direction.Magnitude > 0.01 then
                local heading = direction.Unit
                local obstruction = workspace:Raycast(root.Position, heading * 3, params)
                if obstruction then
                    features.wall_sample={at=os.clock(),name=obstruction.Instance.Name,nx=obstruction.Normal.X,nz=obstruction.Normal.Z}
                    local slide = not safe and wall_heading(root, toward, obstruction.Normal, params, os.clock())
                    if slide then
                        direction, reason = slide, "Following wall: " .. obstruction.Instance.Name
                    else
                        direction = Vector3.zero
                        features.movement_blocked = true
                        reason = "Wall blocked; waiting for recovery: " .. obstruction.Instance.Name
                    end
                end
                if direction.Magnitude > 0.01 then
                    local origin = root.Position + Vector3.new(0, 3, 0)
                    local ahead = origin + direction.Unit * math.clamp(humanoid.WalkSpeed * direction.Magnitude * 0.25, 1, 4)
                    local down = Vector3.new(0, -30, 0)
                    -- A missing ray hit everywhere is not evidence of a ledge.
                    local current_floor = workspace:Raycast(origin, down, params)
                    if current_floor and not workspace:Raycast(ahead, down, params) then
                        direction = Vector3.zero
                        reason = "Ledge ahead: waiting for route"
                    end
                end
            end
            if reason == "No safe movement direction: walls / ledges" then features.movement_blocked = true end
            planned = direction
            movement_note = reason
            if features.record_movement then features.record_movement(root, direction, reason, navigation_key) end
        end
        steering = steering:Lerp(planned, 1 - math.exp(-16 * dt))
        if steering.Magnitude > 1 then steering = steering.Unit end
        humanoid:Move(steering, false)
        local enemy = target and enemy_root(target)
        local face = enemy and flat(enemy.Position - root.Position) or (delta.Magnitude <= config.cast_range and delta or steering)
        local aim_point = features.aim_point
        if enemy and aim_point and aim_point.model == target and os.clock() < aim_point.expires then face = flat(aim_point.position - root.Position) end
        local gaze = features.gaze_target and features.gaze_target()
        if gaze then
            face = flat(root.Position - gaze.Position)
            movement_note = "Looking away from blinding blast"
            local camera = workspace.CurrentCamera
            if camera and camera.CameraType ~= Enum.CameraType.Scriptable then
                local away = flat(camera.CFrame.Position - gaze.Position)
                if away.Magnitude > 0.01 then camera.CFrame = CFrame.lookAt(camera.CFrame.Position, camera.CFrame.Position + away) end
            end
        end
        if face.Magnitude > 0.01 then
            local aim = CFrame.lookAt(root.Position, root.Position + face)
            root.CFrame = root.CFrame:Lerp(aim, 1 - math.exp(-18 * dt))
        end
    end)
    if not ok then release_movement(); movement_note = "Movement error: " .. tostring(err) end
end
Run:BindToRenderStep(render_name, Enum.RenderPriority.Character.Value + 1, movement_frame)
if Run.Heartbeat then
    connections[#connections + 1] = Run.Heartbeat:Connect(function(dt)
        if session.alive and session.enabled and os.clock() - (features.last_render_tick or 0) > 0.35 then
            movement_frame(math.min(dt, 0.1), true)
        end
    end)
end
]==]
local run, err = loadstring(source)
assert(run, err)
run(source)
