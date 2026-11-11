-- The Journal's Progression tab (mod-individual-progression): the stage your character is at and, in
-- order, everything to do there to reach the next one: levels, attunement quest chains with who gives
-- each quest and where, keys to carry, and the raid's bosses down to the one whose kill moves you on.
-- The stages are on the left; the one you're at opens by default, and the tab moves on with you when
-- you reach the next. Tiers.lua has the steps.
--
-- Everything else comes from what the Journal already asks the realm (mod-forever-journal): your stage,
-- each raid's bosses and lockout, quest givers and states (the Quests tab's search), objectives and map
-- flags. Quests you've done come from the client itself (GetQuestsCompleted), which also shows a new
-- stage as soon as it's reached: mod-individual-progression records each stage as a hidden quest
-- (66000 + stage).

local J = Journal
local P = JournalProgression

if not (J and J.RegisterTab and (J.API or 0) >= 1 and J.CreateInset and J.CreateScrollArea
		and J.LoadInstances and J.LoadBosses and J.LoadStatus and P and P.tiers) then return end

local Q = J.QUEST
local setShown = J.SetShown or function (f, shown) if shown then f:Show() else f:Hide() end end

local STAGE_QUEST = 66000
local MAX_STAGE = 18
local LIST_WIDTH = 230
local ROW_HEIGHT = 20
local ROWS = 21
-- The realm is asked about the first quests still to do in the stage shown (who gives them, why one is
-- held back), and again about the first few of them after a quest log change.
local ASK = 12
local RECHECK = 4

local ERAS = { [0] = "Classic", [1] = "Burning Crusade", [2] = "Wrath of the Lich King" }
local STANDINGS = { [4] = "Neutral", [5] = "Friendly", [6] = "Honored", [7] = "Revered", [8] = "Exalted" }
-- Quests steps wait for that aren't steps themselves.
local NAMES = { [8743] = "Bang a Gong!" }

-- The last stage has nothing left to do.
P.tiers[MAX_STAGE] = P.tiers[MAX_STAGE] or { stage = MAX_STAGE, name = "All caught up", era = 2,
	goal = "You've reached the last progression stage: every raid is open to you.", sections = {} }

local order = {}
for stage in pairs(P.tiers) do table.insert(order, stage) end
table.sort(order)

-- Every step by its key (q<quest>, i<item>, lvl<level>, rep<faction>, gear<ilvl>), from the first stage it's in.
local byKey = {}
for _, stage in ipairs(order) do
	local t = P.tiers[stage]
	for _, sec in ipairs(t.sections) do
		sec.tier = t
		for _, s in ipairs(sec.steps or {}) do
			if s.kind == "quest" then s.key = "q" .. s.quest
			elseif s.kind == "item" then s.key = "i" .. s.item
			elseif s.kind == "level" then s.key = "lvl" .. s.level
			elseif s.kind == "rep" then s.key = "rep" .. s.rep
			elseif s.kind == "gear" then s.key = "gear" .. s.ilvl end
			s.tier = t
			byKey[s.key] = byKey[s.key] or s
		end
	end
end

-- What waits for each step: a quest or reputation that something later already needed is behind you,
-- even when the realm gave you the later one outright (IndividualProgression.AutoAttune).
local waitedOnBy = {}
for _, stage in ipairs(order) do
	for _, sec in ipairs(P.tiers[stage].sections) do
		for _, s in ipairs(sec.steps or {}) do
			for _, list in ipairs({ s.after or {}, s.afterAny or {} }) do
				for _, key in ipairs(list) do
					waitedOnBy[key] = waitedOnBy[key] or {}
					table.insert(waitedOnBy[key], s)
				end
			end
		end
	end
end

-- The stage the character's progression is in: the one whose range has it.
local function tierFor(stage)
	local found = P.tiers[order[1]]
	for _, s in ipairs(order) do
		if s <= stage then found = P.tiers[s] end
	end
	return found
end

-----------------------------------------
-- what the character has done

local S = {
	completed = {},     -- quests turned in, from the client
	haveCompleted = false,
	log = {},           -- quest log: 1 in it, 2 ready to turn in
	info = {},          -- the realm's word on a quest (the Quests tab's rows): state, giver, where
	searched = {},      -- quest searches answered, by text
	changedAt = 0,      -- the last quest log change: older realm states may be out of date
	stage = 0,
}

local function faction() return UnitFactionGroup("player") end

local function visible(step)
	return not step.faction or step.faction == faction()
end

-- The stage: the realm's, or the hidden quests' when the client knows of a later one already.
local function updateStage()
	local stage = J.state or MAX_STAGE
	if S.haveCompleted and J.Has(J.HELLO_PROGRESSION) then
		for i = MAX_STAGE, 1, -1 do
			if S.completed[STAGE_QUEST + i] then
				if i > stage then stage = i end
				break
			end
		end
	end
	S.stage = stage
	return stage
end

local function scanLog()
	local log = {}
	for i = 1, GetNumQuestLogEntries() do
		local _, _, _, _, isHeader, _, isComplete, _, id = GetQuestLogTitle(i)
		if id and not isHeader then log[id] = (isComplete == 1) and 2 or 1 end
	end
	S.log = log
end

local function askCompleted()
	if QueryQuestsCompleted then QueryQuestsCompleted() end
end

local function bagCount(step)
	local bags, all = 0, 0
	for _, id in ipairs(step.items or { step.item }) do
		bags = bags + (GetItemCount(id) or 0)
		all = all + (GetItemCount(id, true) or 0)
	end
	return bags, all
end

-- Your standing with a faction (4 Neutral .. 8 Exalted), or nil when the client can't tell.
local function standingWith(id)
	if GetFactionInfoByID then
		local ok, name, _, standingID = pcall(GetFactionInfoByID, id)
		if ok and name then return standingID end
	end
	local want = P.FACTIONS and P.FACTIONS[id]
	if not want then return nil end
	for i = 1, GetNumFactions() do
		local name, _, standingID, _, _, _, _, _, isHeader = GetFactionInfo(i)
		if name == want and not isHeader then return standingID end
	end
end

local gearInfo -- below, with the gear check

local function questDone(id)
	if S.completed[id] then return true end
	local info = S.info[id]
	return info and info.state == Q.DONE or false
end

-- Recomputed for every render.
local memo = {}

local isDone

-- Done, or no longer needed because something that waited for it is done.
local function passed(step)
	if step.kind ~= "quest" and step.kind ~= "rep" then return false end
	for _, later in ipairs(waitedOnBy[step.key] or {}) do
		if later.kind == "quest" and isDone(later) then return true end
	end
	return false
end

isDone = function (step)
	if memo[step] ~= nil then return memo[step] end
	memo[step] = false -- a loop in the data can't recurse forever
	local done = false
	if step.kind == "quest" then
		done = questDone(step.quest) or (step.advances and S.stage >= step.advances) or false
		for _, id in ipairs(step.also or {}) do
			if questDone(id) then done = true end
		end
	elseif step.kind == "item" then
		local bags = bagCount(step)
		done = bags >= (step.count or 1)
	elseif step.kind == "level" then
		done = UnitLevel("player") >= step.level
	elseif step.kind == "rep" then
		local have = standingWith(step.rep)
		done = have ~= nil and have >= step.standing
	elseif step.kind == "gear" then
		done = gearInfo().average >= step.ilvl
	end
	if not done and passed(step) then done = "passed" end
	memo[step] = done
	return done
end

local function keyDone(key)
	local step = byKey[key]
	if step then return isDone(step) end
	local id = tonumber(key:match("^q(%d+)$"))
	return id and questDone(id) or false
end

local function keyName(key)
	local step = byKey[key]
	if step then return step.name end
	local id = tonumber(key:match("^q(%d+)$"))
	if id then return NAMES[id] or (S.info[id] and S.info[id].name) or ("quest " .. id) end
	return key
end

-- A step of the other faction never holds anything up.
local function counts(key)
	local step = byKey[key]
	return not step or visible(step)
end

-- The first thing a step waits for, as text; nil when nothing.
local function waitingFor(step)
	for _, key in ipairs(step.after or {}) do
		if counts(key) and not keyDone(key) then return keyName(key) end
	end
	if step.afterAny then
		local names, any = {}, false
		for _, key in ipairs(step.afterAny) do
			if counts(key) then
				if keyDone(key) then any = true break end
				-- the other way through (Bang a Gong!) isn't offered as a step
				if byKey[key] then table.insert(names, keyName(key)) end
			end
		end
		if not any and #names > 0 then return table.concat(names, " or ") end
	end
end

-----------------------------------------
-- gear: the average item level, DragonUI's when it's there so the number matches its character panel

local GEAR_SLOTS = {
	{ 1, "Head" }, { 2, "Neck" }, { 3, "Shoulder" }, { 15, "Back" }, { 5, "Chest" }, { 9, "Wrist" },
	{ 10, "Hands" }, { 6, "Waist" }, { 7, "Legs" }, { 8, "Feet" }, { 11, "Ring" }, { 12, "Ring" },
	{ 13, "Trinket" }, { 14, "Trinket" }, { 16, "Main hand" }, { 17, "Off hand" }, { 18, "Ranged" },
}
-- How far under the suggestion still counts as nearly there.
local GEAR_SLACK = 5

-- { average, gearScore, slots = { { name, ilvl } } (equipped), empty = { names } }
gearInfo = function ()
	local slots, empty, total = {}, {}, 0
	local twoHander = false
	for _, s in ipairs(GEAR_SLOTS) do
		local link = GetInventoryItemLink("player", s[1])
		if link then
			local _, _, _, ilvl, _, _, _, _, equipLoc = GetItemInfo(link)
			if not ilvl then J.QueryItem(tonumber(link:match("item:(%d+)"))) end
			if equipLoc == "INVTYPE_2HWEAPON" and s[1] == 16 then twoHander = true end
			if ilvl and ilvl > 0 then
				table.insert(slots, { s[2], ilvl })
				total = total + ilvl
			end
		elseif not (s[1] == 17 and twoHander) then
			table.insert(empty, s[2])
		end
	end
	local D = _G.DragonUI
	local average = D and D.GetAverageItemLevel and D.GetAverageItemLevel("player")
	if not average and #slots > 0 then average = math.floor(total / #slots + 0.5) end
	local score = D and D.CharacterPanel and D.CharacterPanel.GetGearScore and D.CharacterPanel.GetGearScore("player")
	table.sort(slots, function (a, b) return a[2] < b[2] end)
	return { average = average or 0, gearScore = score and score > 0 and score or nil, slots = slots, empty = empty }
end

-----------------------------------------
-- step states

local ST = {
	DONE = { icon = "Interface\\RaidFrame\\ReadyCheck-Ready", color = { 0.55, 0.55, 0.55 } },
	READY = { icon = "Interface\\GossipFrame\\ActiveQuestIcon", color = { 0.3, 1, 0.3 } },
	ACTIVE = { icon = "Interface\\GossipFrame\\IncompleteQuestIcon", color = { 0.5, 0.75, 1 } },
	TODO = { icon = "Interface\\GossipFrame\\AvailableQuestIcon", color = { 1, 0.82, 0 } },
	WAIT = { icon = "Interface\\LFGFrame\\UI-LFG-ICON-LOCK", color = { 0.8, 0.6, 0.4 } },
	LOW = { icon = "Interface\\GossipFrame\\AvailableQuestIcon", color = { 1, 0.35, 0.35 }, grey = true },
	LOCKED = { icon = "Interface\\LFGFrame\\UI-LFG-ICON-LOCK", color = { 0.6, 0.6, 0.6 } },
	ERA = { icon = "Interface\\LFGFrame\\UI-LFG-ICON-LOCK", color = { 1, 0.33, 0.33 } },
	WARN = { icon = "Interface\\DialogFrame\\UI-Dialog-Icon-AlertNew", color = { 1, 0.5, 0.15 } },
	KILLED = { icon = "Interface\\RaidFrame\\ReadyCheck-Ready", color = { 0.3, 1, 0.3 } },
	OPTIONAL = { icon = "Interface\\TargetingFrame\\UI-TargetingFrame-Skull", color = { 0.6, 0.6, 0.6 }, grey = true },
	BOSS = { icon = "Interface\\TargetingFrame\\UI-TargetingFrame-Skull", color = { 1, 0.82, 0 } },
}

-- A quest's state, from the client's own knowledge first and the realm's for the rest. The realm's
-- word on why a quest is held back is only trusted from after the last quest log change.
local function questState(step)
	local done = isDone(step)
	if done == "passed" then return ST.DONE, "Not needed now" end
	if done then return ST.DONE, "Done" end
	local id = step.quest
	local inLog = S.log[id]
	for _, other in ipairs(step.also or {}) do inLog = inLog or S.log[other] end
	if inLog == 2 then return ST.READY, "Ready to turn in" end
	if inLog == 1 then return ST.ACTIVE, "In your quest log" end
	local info = S.info[id]
	if info and J.Has(J.HELLO_PROGRESSION) and (info.era or 0) > S.stage then
		return ST.ERA, "Opens at stage " .. info.era
	end
	local wait = waitingFor(step)
	if wait then return ST.WAIT, "First: " .. wait end
	if step.level and UnitLevel("player") < step.level then return ST.LOW, "Needs level " .. step.level end
	if step.rep then
		local have = standingWith(step.rep)
		if have and have < (step.standing or 5) then
			return ST.LOCKED, "Needs " .. (P.FACTIONS[step.rep] or "reputation") .. ": " .. STANDINGS[step.standing or 5]
		end
	end
	if info and (info.at or 0) >= S.changedAt then
		if info.state == Q.LOW_LEVEL then return ST.LOW, "Needs level " .. (info.minLevel or step.level or "?") end
		if info.state == Q.PREREQ then return ST.WAIT, "Needs an earlier quest" end
		if info.state == Q.LOCKED then return ST.LOCKED, "Not available to you yet" end
		if info.state == Q.ERA then return ST.ERA, "Later progression stage" end
	end
	return ST.TODO, "To do"
end

local function stepState(step)
	if step.kind == "quest" then return questState(step) end
	if step.kind == "gear" then
		local average = gearInfo().average
		if average >= step.ilvl then return ST.DONE, "Ready: item level " .. average end
		if average >= step.ilvl - GEAR_SLACK then return ST.WARN, "A bit under: item level " .. average end
		return ST.LOW, "Not yet: item level " .. average
	end
	local done = isDone(step)
	if done == "passed" then return ST.DONE, "Not needed now" end
	if done then
		if step.kind == "item" then return ST.DONE, "In your bags" end
		return ST.DONE, "Done"
	end
	if step.kind == "item" then
		local bags, all = bagCount(step)
		if all > bags then return ST.WARN, "In your bank: carry it" end
		local wait = waitingFor(step)
		if wait then return ST.WAIT, "First: " .. wait end
		return ST.TODO, "To get"
	elseif step.kind == "level" then
		return ST.TODO, "You're level " .. UnitLevel("player")
	elseif step.kind == "rep" then
		local have = standingWith(step.rep)
		if have then return ST.TODO, "You're " .. (STANDINGS[have] or "below Neutral") end
		return ST.TODO, "Check your reputation"
	end
	return ST.TODO, ""
end

-----------------------------------------
-- the realm's quest rows: who gives a quest, where, and its state (the Quests tab's search)

local queue, queued, pumping = {}, {}, false

-- The search drops ':' and ';', so a name is searched by its longest piece without them.
local function searchText(name)
	local best = ""
	for piece in (name .. ":"):gmatch("([^:;|]*)[:;|]") do
		piece = piece:match("^%s*(.-)%s*$")
		if #piece > #best then best = piece end
	end
	return best
end

local render

-- Answers can come at once from a cache, in the middle of a render: the render they ask for waits.
local function later()
	if render then J.Debounce("progression-render", 0.05, function () render() end) end
end

local function pump()
	if pumping then return end
	local text = table.remove(queue, 1)
	if not text then return end
	pumping = true
	J.SearchQuests(text, function (list)
		queued[text] = nil
		S.searched[text] = GetTime()
		for _, q in ipairs(list or {}) do
			q.at = GetTime()
			S.info[q.id] = q
		end
		later()
		-- X costs the realm's budget twice a plain request: keep well inside it.
		J.After(0.6, function ()
			pumping = false
			pump()
		end)
	end)
end

local function ask(step, again)
	if not J.Has(J.HELLO_QUESTS) then return end
	local text = searchText(step.name)
	if #text < 3 or queued[text] then return end
	local at = S.searched[text]
	if at and not (again and at < S.changedAt) then return end
	queued[text] = true
	table.insert(queue, text)
	pump()
end

-----------------------------------------
-- raids: the instance, its tabs for this stage, bosses and lockout

local raids = {}  -- [section] = { inst =, variants =, bosses =, st = }
local lastRaidAsk = {}

local function loadRaid(sec, force)
	local r = raids[sec] or {}
	raids[sec] = r
	if not force and lastRaidAsk[sec] and GetTime() - lastRaidAsk[sec] < 5 then return end
	lastRaidAsk[sec] = GetTime()
	J.LoadInstances(function (byId, list)
		if not list then return end
		local inst
		for _, i in ipairs(list) do
			if i.map == sec.raid and i.raid then inst = i break end
		end
		if not inst then r.missing = true return end
		r.inst = inst
		r.variants = {}
		for _, v in ipairs(inst.variants) do
			if (sec.players and v.players == sec.players) or (not sec.players and (sec.expansion == nil or v.expansion == sec.expansion)) then
				table.insert(r.variants, v)
			end
		end
		J.LoadBosses(inst, function (bosses)
			r.bosses = bosses
			later()
		end)
		J.LoadStatus(inst, function (st)
			if st then r.st = st end
			later()
		end, force)
	end)
end

local function variantLocked(v)
	return J.Has(J.HELLO_PROGRESSION) and (v.reqState or 0) > S.stage
end

-- The bosses of a raid section, in the journal's order, with the stage's milestone marked.
local function raidRows(sec)
	local r = raids[sec]
	if not r or not r.inst or not r.bosses then return nil end
	local out = {}
	for _, b in ipairs(r.bosses) do
		if not b.rare then
			local on = #r.variants == 0
			for _, v in ipairs(r.variants) do
				if J.BossOnVariant(b, v) then on = true end
			end
			if on then table.insert(out, { boss = b }) end
		end
	end
	-- Bosses after the milestone are optional; a milestone this realm names otherwise marks nothing.
	local milestone
	if sec.milestone then
		local want = sec.milestone:lower()
		for i, row in ipairs(out) do
			if row.boss.name:lower() == want or row.boss.name:lower():find(want, 1, true) then milestone = i break end
		end
	end
	-- A boss and those after it may need more than the raid does (the Firelord runes for Majordomo).
	local gate
	if sec.gate then
		local want = sec.gate:lower()
		for i, row in ipairs(out) do
			if row.boss.name:lower() == want or row.boss.name:lower():find(want, 1, true) then gate = i break end
		end
	end
	for i, row in ipairs(out) do
		row.milestone = i == milestone
		row.optional = milestone ~= nil and i > milestone
		row.gated = gate ~= nil and i >= gate
	end
	return out, r
end

local function bossState(sec, row, r)
	local t = sec.tier
	if t.next and S.stage >= t.next and not row.optional then return ST.DONE, "Done" end
	local locked = #r.variants > 0
	for _, v in ipairs(r.variants) do
		if not variantLocked(v) then locked = false end
	end
	if locked then
		local need = MAX_STAGE
		for _, v in ipairs(r.variants) do need = math.min(need, v.reqState or 0) end
		return ST.ERA, "Opens at stage " .. need
	end
	for _, key in ipairs(sec.requires or {}) do
		if counts(key) and not keyDone(key) then return ST.WAIT, "First: " .. keyName(key) end
	end
	if row.gated then
		for _, key in ipairs(sec.gateRequires or {}) do
			if counts(key) and not keyDone(key) then return ST.WAIT, "Needs: " .. keyName(key) end
		end
	end
	for _, v in ipairs(r.variants) do
		if r.st and J.Killed(r.st, v, row.boss) then
			local sv = r.st.variants[v.id]
			local left = sv and sv.resetIn and sv.resetIn > 0 and (" (resets in " .. J.Duration(sv.resetIn - (GetTime() - (sv.at or GetTime()))) .. ")") or ""
			return ST.KILLED, "Killed this lockout" .. left
		end
	end
	if row.optional then return ST.OPTIONAL, "Optional" end
	if row.milestone and t.next then return ST.BOSS, "Moves you to stage " .. t.next end
	return ST.BOSS, "Not killed this lockout"
end

-----------------------------------------
-- the tab

local function build(panel)
	JournalProgressionCharDB = JournalProgressionCharDB or {}
	local db = JournalProgressionCharDB

	local view = { selected = nil, follow = true, open = nil, lastStage = nil }

	local status = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	status:SetPoint("CENTER", panel, "CENTER", 0, 20)
	status:SetWidth(520)
	local statusSub = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	statusSub:SetPoint("TOP", status, "BOTTOM", 0, -10)
	statusSub:SetWidth(520)

	local body = CreateFrame("Frame", nil, panel)
	body:SetAllPoints(panel)

	-- left: your stage, the filter and every stage

	local left = CreateFrame("Frame", nil, body)
	left:SetPoint("TOPLEFT", body, "TOPLEFT", 0, 0)
	left:SetPoint("BOTTOMLEFT", body, "BOTTOMLEFT", 0, 0)
	left:SetWidth(LIST_WIDTH)

	local stageText = left:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	stageText:SetPoint("TOPLEFT", left, "TOPLEFT", 8, -8)
	stageText:SetPoint("RIGHT", left, "RIGHT", -8, 0)
	stageText:SetJustifyH("LEFT")

	local hideDone = J.CreateCheck(left, "Hide steps I've done")
	hideDone:SetPoint("TOPLEFT", left, "TOPLEFT", 2, -22)
	hideDone:SetScript("OnClick", function (self)
		db.hideDone = self:GetChecked() and true or nil
		render()
	end)

	local listInset = J.CreateInset(left)
	listInset:SetPoint("TOPLEFT", left, "TOPLEFT", 0, -46)
	listInset:SetPoint("BOTTOMRIGHT", left, "BOTTOMRIGHT", 0, 0)

	local scrollName = J.UniqueName("ProgressionStageScroll")
	local scroll = CreateFrame("ScrollFrame", scrollName, listInset, "FauxScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", listInset, "TOPLEFT", 4, -4)
	scroll:SetPoint("BOTTOMRIGHT", listInset, "BOTTOMRIGHT", -26, 4)
	J.SkinScrollBar(scroll, scrollName)

	-- right: the stage's steps

	local right = J.CreateInset(body)
	right:SetPoint("TOPLEFT", left, "TOPRIGHT", 8, 0)
	right:SetPoint("BOTTOMRIGHT", body, "BOTTOMRIGHT", 0, 0)

	local title = right:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", right, "TOPLEFT", 12, -10)
	title:SetPoint("RIGHT", right, "RIGHT", -12, 0)
	title:SetJustifyH("LEFT")
	local subtitle = right:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	subtitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -4)
	subtitle:SetPoint("RIGHT", right, "RIGHT", -12, 0)
	subtitle:SetJustifyH("LEFT")

	local area = J.CreateScrollArea(right)
	area:SetPoint("TOPLEFT", right, "TOPLEFT", 8, -44)
	area:SetPoint("BOTTOMRIGHT", right, "BOTTOMRIGHT", -30, 8)
	area:SetScript("OnMouseWheel", function (self, delta)
		local max = math.max(0, self.content:GetHeight() - self:GetHeight())
		self:SetVerticalScroll(math.max(0, math.min(max, self:GetVerticalScroll() - delta * 60)))
	end)
	local c = area.content

	local empty = right:CreateFontString(nil, "OVERLAY", "GameFontDisable")
	empty:SetPoint("TOP", right, "TOP", 0, -90)
	empty:SetWidth(380)

	-----------------------------------------
	-- the stage list

	local function selectTier(t)
		if view.selected ~= t then
			view.open = nil
			area:ScrollToTop()
		end
		view.selected = t
		view.follow = t == tierFor(S.stage)
		render()
	end

	local rows = {}
	for i = 1, ROWS do
		local b = CreateFrame("Button", nil, listInset)
		b:SetHeight(ROW_HEIGHT)
		b:SetPoint("TOPLEFT", listInset, "TOPLEFT", 6, -6 - (i - 1) * ROW_HEIGHT)
		b:SetPoint("RIGHT", scroll, "RIGHT", 0, 0)
		b.lock = b:CreateTexture(nil, "ARTWORK")
		b.lock:SetTexture("Interface\\LFGFrame\\UI-LFG-ICON-LOCK")
		b.lock:SetSize(14, 14)
		b.lock:SetPoint("LEFT", b, "LEFT", 4, 0)
		b.right = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		b.right:SetPoint("RIGHT", b, "RIGHT", -4, 0)
		b.right:SetJustifyH("RIGHT")
		b.name = b:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		b.name:SetPoint("RIGHT", b.right, "LEFT", -6, 0)
		b.name:SetJustifyH("LEFT")
		b.selectedBg = b:CreateTexture(nil, "BACKGROUND")
		b.selectedBg:SetAllPoints(b)
		b.selectedBg:SetTexture("Interface\\QuestFrame\\UI-QuestLogTitleHighlight")
		b.selectedBg:SetBlendMode("ADD")
		b.selectedBg:SetVertexColor(1, 0.82, 0, 0.5)
		local hl = b:CreateTexture(nil, "HIGHLIGHT")
		hl:SetAllPoints(b)
		hl:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
		hl:SetBlendMode("ADD")
		b:SetScript("OnClick", function (self)
			if self.tier then
				PlaySound("igMainMenuOptionCheckBoxOn")
				selectTier(self.tier)
			end
		end)
		b:SetScript("OnEnter", function (self)
			local t = self.tier
			if not t then return end
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetText(t.name, 1, 0.82, 0)
			GameTooltip:AddLine("Stage " .. t.stage .. (t.next and (", leads to stage " .. t.next) or ""), 0.8, 0.8, 0.8)
			GameTooltip:AddLine(t.goal, 1, 1, 1, true)
			if t.stage > S.stage then GameTooltip:AddLine("You're at stage " .. S.stage .. ".", 1, 0.33, 0.33) end
			GameTooltip:Show()
		end)
		b:SetScript("OnLeave", function () GameTooltip:Hide() end)
		rows[i] = b
	end

	local entries = {}
	local function buildEntries()
		entries = {}
		local era
		for _, stage in ipairs(order) do
			local t = P.tiers[stage]
			if t.era ~= era then
				era = t.era
				table.insert(entries, { era = era })
			end
			table.insert(entries, { tier = t })
		end
	end
	buildEntries()

	local function renderRows()
		local offset = FauxScrollFrame_GetOffset(scroll)
		local current = tierFor(S.stage)
		for i = 1, ROWS do
			local b = rows[i]
			local e = entries[offset + i]
			b.tier = e and e.tier
			if not e then
				b:Hide()
			else
				b:Show()
				b.name:ClearAllPoints()
				if e.era then
					b.lock:Hide()
					b.name:SetPoint("LEFT", b, "LEFT", 4, 0)
					b.name:SetPoint("RIGHT", b.right, "LEFT", -6, 0)
					b.name:SetFontObject(GameFontNormal)
					b.name:SetText(ERAS[e.era] or "")
					b.name:SetTextColor(1, 0.82, 0)
					b.right:SetText("")
					b.selectedBg:Hide()
				else
					local t = e.tier
					local future = t.stage > S.stage
					local done = t.next and S.stage >= t.next
					setShown(b.lock, future)
					b.name:SetPoint("LEFT", b, "LEFT", 22, 0)
					b.name:SetPoint("RIGHT", b.right, "LEFT", -6, 0)
					b.name:SetFontObject(GameFontHighlightSmall)
					b.name:SetText("|cff808080" .. t.stage .. "|r  " .. t.name)
					if future then b.name:SetTextColor(0.6, 0.6, 0.6) else b.name:SetTextColor(1, 1, 1) end
					if t == current then
						b.right:SetText("|cffffd200Now|r")
					elseif done then
						b.right:SetText("|cff40ff40Done|r")
					else
						b.right:SetText("")
					end
					setShown(b.selectedBg, t == view.selected)
				end
			end
		end
		FauxScrollFrame_Update(scroll, #entries, ROWS, ROW_HEIGHT)
	end

	scroll:SetScript("OnVerticalScroll", function (self, offset)
		FauxScrollFrame_OnVerticalScroll(self, offset, ROW_HEIGHT, renderRows)
	end)

	-----------------------------------------
	-- the steps: section headers and step rows, laid out top to bottom

	local function makeHeader()
		local h = CreateFrame("Frame", nil, c)
		h:SetHeight(22)
		if J.dragon then
			h.band = h:CreateTexture(nil, "BACKGROUND")
			h.band:SetAllPoints(h)
			h.band:SetTexture(0.2, 0.14, 0.04, 0.9)
			h.rule = h:CreateTexture(nil, "BORDER")
			h.rule:SetHeight(1)
			h.rule:SetPoint("BOTTOMLEFT", h, "BOTTOMLEFT")
			h.rule:SetPoint("BOTTOMRIGHT", h, "BOTTOMRIGHT")
			h.rule:SetTexture(1, 0.82, 0, 0.55)
		else
			J.CreateHeaderBand(h)
		end
		h.text = h:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		h.text:SetPoint("LEFT", h, "LEFT", 6, 0)
		h.extra = h:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		h.extra:SetPoint("RIGHT", h, "RIGHT", -6, 0)
		h.button = J.CreateButton(h, "Open in Journal", 120, 18)
		h.button:SetPoint("RIGHT", h.extra, "LEFT", -8, 0)
		h.button:SetScript("OnClick", function (self)
			local inst = self:GetParent().inst
			if inst then J.OpenInstance(inst.id, { variant = self:GetParent().variant }) end
		end)
		return h
	end

	local function makeNote()
		local n = CreateFrame("Frame", nil, c)
		n.text = n:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		n.text:SetPoint("TOPLEFT", n, "TOPLEFT", 8, -4)
		n.text:SetJustifyH("LEFT")
		n.text:SetJustifyV("TOP")
		n.text:SetTextColor(0.75, 0.75, 0.75)
		return n
	end

	local function makeRow()
		local r = CreateFrame("Button", nil, c)
		r.icon = r:CreateTexture(nil, "ARTWORK")
		r.icon:SetSize(16, 16)
		r.icon:SetPoint("TOPLEFT", r, "TOPLEFT", 20, -4)
		r.arrow = r:CreateTexture(nil, "ARTWORK")
		r.arrow:SetTexture("Interface\\ChatFrame\\ChatFrameExpandArrow")
		r.arrow:SetSize(12, 14)
		r.arrow:SetPoint("RIGHT", r.icon, "LEFT", -3, 0)
		r.name = r:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		r.name:SetPoint("TOPLEFT", r, "TOPLEFT", 42, -5)
		r.name:SetJustifyH("LEFT")
		r.status = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		r.status:SetPoint("TOPRIGHT", r, "TOPRIGHT", -6, -6)
		r.status:SetJustifyH("RIGHT")
		r.sub = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		r.sub:SetPoint("TOPLEFT", r.name, "BOTTOMLEFT", 0, -3)
		r.sub:SetJustifyH("LEFT")
		r.sub:SetJustifyV("TOP")
		r.sub:SetTextColor(0.75, 0.75, 0.75)
		r.detail = r:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
		r.detail:SetJustifyH("LEFT")
		r.detail:SetJustifyV("TOP")
		r.mapButton = J.CreateButton(r, "Show on map", 130, 20)
		r.mapButton:SetScript("OnClick", function (self)
			local e = self:GetParent().entry
			if not e then return end
			if e.step and e.step.kind == "quest" then J.ShowOnMap("Q", e.step.quest)
			elseif e.raid and e.raid.inst then J.ShowOnMap("E", e.raid.inst.id) end
		end)
		r.journalButton = J.CreateButton(r, "Open in Journal", 130, 20)
		r.journalButton:SetScript("OnClick", function (self)
			local e = self:GetParent().entry
			if e and e.raid and e.raid.inst then
				J.OpenInstance(e.raid.inst.id, { boss = e.row.boss.key, variant = e.raid.variants[1] and e.raid.variants[1].id })
			end
		end)
		r.band = r:CreateTexture(nil, "BACKGROUND")
		r.band:SetAllPoints(r)
		local hl = r:CreateTexture(nil, "HIGHLIGHT")
		hl:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
		hl:SetBlendMode("ADD")
		hl:SetVertexColor(1, 1, 1, 0.15)
		hl:SetAllPoints(r)
		r:SetScript("OnClick", function (self)
			local e = self.entry
			if not e then return end
			if e.step and e.step.kind == "quest" and IsModifiedClick("CHATLINK") then
				local link = string.format("|cffffff00|Hquest:%d:%d|h[%s]|h|r", e.step.quest, e.step.level or 0, e.step.name)
				if not ChatEdit_InsertLink(link) then ChatFrame_OpenChat(link) end
				return
			end
			if e.step and e.step.kind == "item" and IsModifiedClick("CHATLINK") then
				J.HandleItemClick(e.step.item, GetItemInfo(e.step.item), select(3, GetItemInfo(e.step.item)))
				return
			end
			view.open = view.open ~= e.id and e.id or nil
			render()
		end)
		r:SetScript("OnEnter", function (self)
			local e = self.entry
			if e and e.step and e.step.kind == "item" then
				J.ShowItemTooltip(self, e.step.item)
				GameTooltip:Show()
			end
		end)
		r:SetScript("OnLeave", function () GameTooltip:Hide() end)
		return r
	end

	local headers = J.CreatePool(makeHeader)
	local notes = J.CreatePool(makeNote)
	local stepRows = J.CreatePool(makeRow)

	-- Who gives a quest and where, from the realm.
	local function giverText(step)
		local info = S.info[step.quest]
		if not info then return nil end
		local text
		if info.giverKind == "I" then
			text = "Starts from " .. (GetItemInfo(info.giverEntry) or info.giver) .. (info.where ~= "" and (", " .. info.where:lower()) or "")
		elseif info.giver ~= "" then
			text = info.giver .. (info.where ~= "" and ("  -  " .. info.where) or "")
		end
		return text
	end

	-- The lines under a step's name.
	local function subText(e)
		local lines = {}
		local step = e.step
		if step then
			if step.kind == "quest" then
				local g = giverText(step)
				if g then table.insert(lines, g) end
				if step.alt then table.insert(lines, "|cffffd200" .. step.alt .. ":|r do this chain or the other one") end
			end
			if step.note then table.insert(lines, "|cff9d9d9d" .. step.note .. "|r") end
			if step.optional then table.insert(lines, "|cff9d9d9dNot needed to move on.|r") end
			if step.kind == "gear" then
				local g = gearInfo()
				table.insert(lines, "Your average item level: |cffffffff" .. g.average .. "|r"
					.. (g.gearScore and ("  -  GearScore |cffffffff" .. g.gearScore .. "|r") or "")
					.. "  |cff9d9d9d(advice: it doesn't hold anything up)|r")
			end
		elseif e.row then
			if e.row.milestone then table.insert(lines, "|cffffd200The kill that moves you on.|r") end
		end
		return table.concat(lines, "\n")
	end

	local function detailText(e, d, mine)
		local step = e.step
		if step and step.kind == "quest" then
			local function fill(detail)
				if not detail then d:SetText("The objectives couldn't be loaded.") return end
				local lines = {}
				if detail.objectives ~= "" then table.insert(lines, detail.objectives) end
				for _, k in ipairs(detail.kills) do
					table.insert(lines, "|cffffd200-|r " .. (k.target < 0 and "Use " or "Slay ") .. k.name
						.. (k.count and k.count > 1 and (" x" .. k.count) or ""))
				end
				for _, it in ipairs(detail.items) do
					table.insert(lines, "|cffffd200-|r " .. (GetItemInfo(it.item) or it.name) .. (it.count > 1 and (" x" .. it.count) or ""))
				end
				if detail.prev then
					table.insert(lines, (detail.prev.done and "|cff40ff40Done:|r " or "|cffff6060First:|r ") .. detail.prev.name)
				end
				d:SetText(#lines > 0 and table.concat(lines, "\n") or "No objectives listed.")
			end
			d:SetText("Loading...")
			local waiting = true
			J.LoadQuestDetail(step.quest, function (detail)
				if mine ~= view.serial then return end
				fill(detail)
				if detail and not waiting then render() end
			end)
			waiting = false
			return true
		elseif e.row then
			local lines = {}
			local inst = e.raid.inst
			table.insert(lines, inst.name .. (inst.zone ~= "" and (", " .. inst.zone) or ""))
			if e.row.milestone then
				table.insert(lines, "Killing " .. e.row.boss.name .. " moves you to progression stage " .. (e.sec.tier.next or "?") .. ".")
			end
			d:SetText(table.concat(lines, "\n"))
			return true
		elseif step and step.kind == "item" then
			d:SetText(step.note or "")
			return step.note ~= nil
		elseif step and step.kind == "gear" then
			-- Where to look for upgrades: what's missing, then the lowest pieces worn.
			local g = gearInfo()
			local lines = {}
			if #g.empty > 0 then table.insert(lines, "|cffff6060Nothing equipped:|r " .. table.concat(g.empty, ", ")) end
			local low = {}
			for i = 1, math.min(5, #g.slots) do
				if g.slots[i][2] < step.ilvl then table.insert(low, g.slots[i][1] .. " " .. g.slots[i][2]) end
			end
			if #low > 0 then table.insert(lines, "|cffffd200Lowest:|r " .. table.concat(low, ", ")) end
			if #lines == 0 then table.insert(lines, "Every piece you wear is at the suggested item level or above.") end
			d:SetText(table.concat(lines, "\n"))
			return true
		end
		return false
	end

	-- What's shown: section headers, their notes and the steps, in order.
	local function collect(t)
		local list = {}
		for si, sec in ipairs(t.sections) do
			local header = { header = sec, done = 0, total = 0 }
			table.insert(list, header)
			if sec.note then table.insert(list, { note = sec.note }) end
			if sec.raid then
				loadRaid(sec)
				local bosses, r = raidRows(sec)
				header.raid = r
				if not bosses then
					local missing = raids[sec] and raids[sec].missing
					table.insert(list, { note = missing and "This realm's journal doesn't list this raid." or "Loading the bosses..." })
				else
					for bi, row in ipairs(bosses) do
						local state, text = bossState(sec, row, r)
						local done = state == ST.DONE or state == ST.KILLED
						if not row.optional then
							header.total = header.total + 1
							if done then header.done = header.done + 1 end
						end
						if not (db.hideDone and done) then
							table.insert(list, { id = "b" .. si .. ":" .. bi, row = row, raid = r, sec = sec, state = state, text = text,
								optional = row.optional, done = done })
						end
					end
				end
			else
				-- Of steps for the Aldor or the Scryers, only one side's once you've started on it.
				local chosen
				for _, step in ipairs(sec.steps) do
					if step.alt and visible(step) and (isDone(step) or S.log[step.quest]) then
						chosen = chosen or step.alt
					end
				end
				for _, step in ipairs(sec.steps) do
					if visible(step) and not (step.alt and chosen and step.alt ~= chosen) then
						local state, text = stepState(step)
						local done = state == ST.DONE
						if not (step.optional or step.recommended) then
							header.total = header.total + 1
							if done then header.done = header.done + 1 end
						end
						if not (db.hideDone and done) then
							table.insert(list, { id = step.key, step = step, state = state, text = text, optional = step.optional or step.recommended, done = done })
						end
					end
				end
			end
		end
		return list
	end

	render = function ()
		if not panel:IsVisible() then return end
		memo = {}
		local stage = updateStage()
		local current = tierFor(stage)
		if view.lastStage ~= stage then
			-- A new stage: show it, whatever was picked before.
			if view.lastStage ~= nil and stage > view.lastStage then view.follow = true end
			view.lastStage = stage
		end
		if view.follow or not view.selected then view.selected = current end
		hideDone:SetChecked(db.hideDone and true or false)
		if J.Has(J.HELLO_PROGRESSION) then
			stageText:SetText("Your progression stage: |cffffffff" .. stage .. "|r")
		else
			stageText:SetText("|cff9d9d9dProgression isn't on for you here|r")
		end
		renderRows()

		local t = view.selected
		view.serial = (view.serial or 0) + 1
		local mine = view.serial
		title:SetText(t.name)
		if t.stage > stage then title:SetTextColor(0.6, 0.6, 0.6) else title:SetTextColor(1, 0.82, 0) end

		headers:Reset()
		notes:Reset()
		stepRows:Reset()

		local list = collect(t)
		local done, total = 0, 0
		for _, e in ipairs(list) do
			if e.header then done, total = done + e.done, total + e.total end
		end
		local bits = { "Stage " .. t.stage .. (t.next and (" to " .. t.next) or "") }
		table.insert(bits, t.goal)
		if t.next and stage >= t.next then
			table.insert(bits, "|cff40ff40Done|r")
		elseif t.stage > stage then
			table.insert(bits, "|cffff5555You're at stage " .. stage .. "|r")
		elseif total > 0 then
			table.insert(bits, done .. " of " .. total .. " steps done")
		end
		subtitle:SetText(table.concat(bits, "  -  "))

		-- The next thing to do: the first step still to do that isn't optional.
		local nextEntry
		if t == current then
			for _, e in ipairs(list) do
				if (e.step or e.row) and not e.done and not e.optional then nextEntry = e break end
			end
		end

		-- Ask the realm about the quests still to do (who gives them, why one is held back).
		local asked = 0
		for _, e in ipairs(list) do
			if e.step and e.step.kind == "quest" and not e.done and asked < ASK then
				ask(e.step, asked < RECHECK)
				asked = asked + 1
			end
		end

		local width = math.max(200, area:GetWidth() - 8)
		local y = 0
		for _, e in ipairs(list) do
			if e.header then
				local h = headers:Get()
				h:ClearAllPoints()
				h:SetPoint("TOPLEFT", c, "TOPLEFT", 0, -y)
				h:SetWidth(width)
				h.text:SetText(e.header.title)
				h.extra:SetText(e.total > 0 and (e.done >= e.total and ("|cff40ff40" .. e.done .. "/" .. e.total .. "|r") or (e.done .. "/" .. e.total)) or "")
				h.inst = e.raid and e.raid.inst
				h.variant = e.raid and e.raid.variants[1] and e.raid.variants[1].id
				setShown(h.button, h.inst ~= nil)
				y = y + 26
			elseif e.note then
				local n = notes:Get()
				n:ClearAllPoints()
				n:SetPoint("TOPLEFT", c, "TOPLEFT", 0, -y)
				n:SetWidth(width)
				n.text:SetWidth(width - 16)
				n.text:SetText(e.note)
				local hgt = n.text:GetStringHeight() + 8
				n:SetHeight(hgt)
				y = y + hgt + 2
			else
				local r = stepRows:Get()
				r.entry = e
				r:ClearAllPoints()
				r:SetPoint("TOPLEFT", c, "TOPLEFT", 0, -y)
				r:SetWidth(width)
				local st = e.state
				local isNext = e == nextEntry
				setShown(r.arrow, isNext)
				if isNext then r.band:SetTexture(1, 0.82, 0, 0.12) else r.band:SetTexture(1, 1, 1, 0.03) end

				local name, icon
				if e.step then
					name = e.step.name
					if e.step.kind == "item" then
						name = GetItemInfo(e.step.item) or e.step.name
						if not GetItemInfo(e.step.item) then J.QueryItem(e.step.item) end
					elseif e.step.kind == "quest" then
						-- The quest's own level, as the Quests tab shows it, once the realm has said.
						local info = S.info[e.step.quest]
						if info and info.level and info.level > 0 then name = "[" .. info.level .. "] " .. name end
					end
					if e.step.alt then name = name .. " |cff9d9d9d(" .. e.step.alt .. ")|r" end
				else
					name = e.row.boss.name
				end
				if e.step and e.step.recommended then name = name .. " |cff9d9d9d(recommended)|r"
				elseif e.optional then name = name .. " |cff9d9d9d(optional)|r" end
				r.name:SetText(name)
				if e.done then r.name:SetTextColor(0.6, 0.6, 0.6)
				elseif isNext then r.name:SetTextColor(1, 1, 1)
				else r.name:SetTextColor(1, 0.82, 0) end
				r.name:SetWidth(width - 200)

				icon = st.icon
				if e.step and e.step.kind == "item" and not e.done then icon = J.ItemIcon(e.step.item) or icon end
				r.icon:SetTexture(icon)
				r.icon:SetDesaturated(st.grey and true or false)

				r.status:SetText(isNext and ("|cffffd200Next:|r " .. e.text) or e.text)
				r.status:SetTextColor(st.color[1], st.color[2], st.color[3])

				r.sub:SetWidth(width - 50)
				r.sub:SetText(subText(e))
				local h = 24
				local subH = (r.sub:GetText() or "") ~= "" and r.sub:GetStringHeight() or 0
				h = h + subH + (subH > 0 and 4 or 0)

				r.mapButton:Hide()
				r.journalButton:Hide()
				if view.open == e.id then
					r.detail:ClearAllPoints()
					r.detail:SetPoint("TOPLEFT", r, "TOPLEFT", 42, -h - 2)
					r.detail:SetWidth(width - 56)
					if detailText(e, r.detail, mine) then
						r.detail:Show()
						h = h + 4 + r.detail:GetStringHeight() + 6
					else
						r.detail:Hide()
					end
					local x = 42
					if J.Has(J.HELLO_MAP_PINS) and ((e.step and e.step.kind == "quest") or e.row) then
						r.mapButton:SetText(e.row and "Show entrance" or "Show giver on map")
						r.mapButton:ClearAllPoints()
						r.mapButton:SetPoint("TOPLEFT", r, "TOPLEFT", x, -h)
						r.mapButton:Show()
						x = x + 136
					end
					if e.row then
						r.journalButton:ClearAllPoints()
						r.journalButton:SetPoint("TOPLEFT", r, "TOPLEFT", x, -h)
						r.journalButton:Show()
					end
					if r.mapButton:IsShown() or r.journalButton:IsShown() then h = h + 26 end
				else
					r.detail:Hide()
				end
				r:SetHeight(h + 2)
				y = y + h + 4
			end
		end
		area:SetContentHeight(y)

		if #list == 0 then
			empty:SetText(t.stage >= MAX_STAGE and "Every raid is open to you. Well done!" or "Nothing listed for this stage.")
			empty:Show()
		else
			empty:Hide()
		end
	end

	-----------------------------------------
	-- loading

	local function showProblem(problem, sub)
		body:Hide()
		status:SetText(problem)
		statusSub:SetText(sub or "")
		status:Show()
		statusSub:Show()
	end

	local function load()
		local problem, sub = J.ServerStatus()
		if not problem and not J.Has(J.HELLO_PROGRESSION) then
			problem, sub = "This realm doesn't track progression",
				"mod-individual-progression isn't running on this realm (or its era locks are off), so every raid is already open."
		end
		if problem then showProblem(problem, sub) return end
		status:Hide()
		statusSub:Hide()
		body:Show()
		scanLog()
		askCompleted()
		-- The raids of the stage you're at: their lockouts, and the realm's word on your stage.
		for _, sec in ipairs(tierFor(updateStage()).sections) do
			if sec.raid then loadRaid(sec, true) end
		end
		render()
	end

	local function shown() return panel:IsVisible() end

	local events = CreateFrame("Frame")
	events:RegisterEvent("QUEST_QUERY_COMPLETE")
	events:RegisterEvent("BAG_UPDATE")
	events:RegisterEvent("UPDATE_FACTION")
	events:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
	events:SetScript("OnEvent", function (self, event)
		if event == "QUEST_QUERY_COMPLETE" then
			local done = {}
			if GetQuestsCompleted then GetQuestsCompleted(done) end
			S.completed = done
			S.haveCompleted = true
			if shown() then render() end
		elseif shown() then
			J.Debounce("progression-render", 0.5, function () render() end)
		end
	end)

	J.On("QUESTS_CHANGED", function ()
		S.changedAt = GetTime()
		scanLog()
		if shown() then
			render()
			-- A turn-in or a stage reached shows in the done list a moment later.
			J.Debounce("progression-completed", 3.0, function () if shown() then askCompleted() end end)
		end
	end)
	J.On("LOCKOUTS_CHANGED", function ()
		if not shown() then return end
		for _, sec in ipairs(view.selected and view.selected.sections or {}) do
			if sec.raid then loadRaid(sec, true) end
		end
		J.Debounce("progression-completed", 3.0, function () if shown() then askCompleted() end end)
	end)
	J.On("ITEM_INFO", function () if shown() then J.Debounce("progression-render", 0.3, function () render() end) end end)
	J.On("SECTION_SERVER", function () if shown() then load() end end)
	J.On("NO_SERVER", function () if shown() then load() end end)

	return load
end

local load
Journal.RegisterTab({
	key = "progression", name = "Progression", order = 22, icon = "Interface\\Icons\\Achievement_Dungeon_ClassicRaider",
	build = function (panel) load = build(panel) end,
	onShow = function () if load then load() end end,
})

-----------------------------------------
-- DragonUI's micro menu: a Progression button that opens the tab, when DragonUI can take one
-- (DragonUI.RegisterMicroButton). DragonUI's micro menu options show or hide it.

local D = _G.DragonUI
if D and D.RegisterMicroButton and not _G.JournalProgressionMicroButton then
	local ART = "Interface\\AddOns\\JournalProgression\\MicroButton"
	-- Four 64x82 states across the top of a 256x256 sheet, as DragonUI's Professions button.
	local function cell(i) return { (i - 1) * 0.25, i * 0.25, 0, 0.3203125, ART } end

	local btn = CreateFrame("Button", "JournalProgressionMicroButton", UIParent)
	btn:SetSize(32, 40)
	btn:Hide()
	btn:SetNormalTexture(ART)
	btn:SetPushedTexture(ART)
	btn:SetDisabledTexture(ART)
	btn:SetHighlightTexture(ART)
	btn:RegisterForClicks("LeftButtonUp")
	btn:SetScript("OnClick", function () J.ToggleSection("progression") end)
	btn:SetScript("OnEnter", function (self)
		if SHOW_NEWBIE_TIPS == "1" then
			GameTooltip_SetDefaultAnchor(GameTooltip, self)
		else
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		end
		GameTooltip:SetText("Progression", 1, 1, 1)
		GameTooltip:AddLine("Your progression stage, and what to do next.", NORMAL_FONT_COLOR.r, NORMAL_FONT_COLOR.g,
			NORMAL_FONT_COLOR.b, true)
		GameTooltip:Show()
	end)
	btn:SetScript("OnLeave", function () GameTooltip:Hide() end)

	D.RegisterMicroButton(btn, { after = "LFD", label = "Progression",
		art = { Up = cell(1), Down = cell(2), Mouseover = cell(3), Disabled = cell(4) } })

	-- Pressed while the journal shows the tab, as the stock buttons are while their window is open.
	local function sync()
		local on = JournalFrame and JournalFrame:IsShown() and J.view and J.view.section == "progression"
		btn:SetButtonState(on and "PUSHED" or "NORMAL")
	end
	hooksecurefunc(J, "Show", sync)
	if JournalFrame then
		JournalFrame:HookScript("OnShow", sync)
		JournalFrame:HookScript("OnHide", sync)
	end
end

SLASH_JOURNALPROGRESSION1 = "/progression"
SlashCmdList.JOURNALPROGRESSION = function () J.ToggleSection("progression") end
