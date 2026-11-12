--------------------------------------------------------------------------------
-- OpenMap: Zephras Isle. OpenMap's stitched world has no place for Zephras Isle (its own continent,
-- Map 2991), so it opens Blizzard's own map of it, flat. This lays the game's minimap on that map, in
-- the canvas, under the pins, and adds zoom levels: mixed in by OpenMap's own settings (Minimap detail,
-- its strength, from which zoom, most opacity, deepest zoom), read only, never changed.
-- And the isle's caves, as OpenMap's Close.lua draws caves that have only the game's minimap of them:
-- each surfaces as you zoom in on it, the land above dims, and over one the zoom goes on past the deepest.
-- They have their own switch: OpenMap's Caves underground also covers Blizzard's cave maps elsewhere.
-- /zephras opens the map; /zephras 50 34.6: centred there, zoomed in; /zephras toggle: the minimap on and
-- off; /zephras caves: the caves (also in OpenMap's menu).
--------------------------------------------------------------------------------

local ADDON, Z = ...

local OM, ns = _G.OpenMapAPI, _G.OpenMap
local S = ns and ns.MapStitch
local mod = ns and ns.GetModule and ns:GetModule("worldmap")

local RU = GetLocale() == "ruRU"
local L = {
	name = RU and "Мини-карта острова Зефрис" or "Zephras Isle minimap",
	caves = RU and "Пещеры острова Зефрис" or "Zephras Isle caves",
	section = RU and "Остров Зефрис" or "Zephras Isle",
	missing = RU and "OpenMap не найден или изменился: мини-карта острова выключена." or "OpenMap is missing or has changed: the isle's minimap is off.",
	on = RU and "Мини-карта острова: включена." or "Isle minimap: on.",
	off = RU and "Мини-карта острова: выключена." or "Isle minimap: off.",
	cavesOn = RU and "Пещеры острова: включены." or "Isle caves: on.",
	cavesOff = RU and "Пещеры острова: выключены." or "Isle caves: off.",
	combat = RU and "В бою карту менять нельзя." or "Not in combat: the map can't be changed.",
}
local function Say(text) print("|cffe6b85cOpenMap: Zephras|r " .. text) end

if not (OM and S and mod and S.Size and S.FromYards) then
	Say(L.missing)
	return
end

-- both of the game's maps of the isle cover the same ground (UiMapAssignment)
local MAPS = { [2521] = true, [2665] = true }
local MIN_X, MIN_Y, MAX_X, MAX_Y = 1247.92, -1331.25, 4956.25, 4231.25   -- yards
local YW, XH = MAX_Y - MIN_Y, MAX_X - MIN_X
local TILE = 1600 / 3                                                    -- yards a minimap tile
local COL0, ROW0, COL1, ROW1 = 25, 22, 34, 30                            -- what Media/Mask covers, in tiles
local MASK = "Interface\\AddOns\\" .. ADDON .. "\\Media\\Mask"

-- as OpenMap's Close.lua draws the minimap, softened and warmed to the parchment
local MINI_DESAT = 0.35
local TINT = { 0.96, 0.87, 0.65 }
local MINI_FADE, DEEP_FADE = { 20, 34 }, { 30, 48 }
local MINI_FROM_LEAST = 1
local miniFade, deepFade = { 20, 34 }, { 30, 48 }
local ZOOM_STEP = 1.25
local FALLBACK_FACTOR, MOST_FACTOR = 10, 64    -- how far past the fit the zoom goes: unknown, and at most

-- ... and its caves (Close.lua's numbers)
local PAPER = { 1, 0.93, 0.80 }
local UNDER_RANGE = { 1.8, 4 }                 -- view / cave, its longer way: fully surfaced .. starting to
local UNDER_ZOOM = { 28, 40 }                  -- and the zoom it waits for
local FOCUS_RANGE = { 0.35, 0.8 }              -- how near the view's centre, for the land above to dim
local DIM = 0.45
local CAVE_MARGIN, CAVE_FILL, CAVE_DEEPER = 0.25, 0.9, 6   -- (WorldMap.lua's: the zoom goes on over a cave)

local map, sc, canvas, frame, mask, under, dim
local textures, caves = {}, {}
local db
local laidW, laidH, lastScale, yardK
local zoomBase, zoomTop, zoomNow               -- the zoom levels' canvas scales: least, deepest off a cave, deepest now
local saved                                    -- { scale, x, y } when the map closed on the isle
local reopenTry = 0                            -- which opening the reopening's timers are for

local function Smooth(x, r)
	local t = math.max(0, math.min(1, (x - r[1]) / (r[2] - r[1])))
	return t * t * (3 - 2 * t)
end

local function OnIsle() return sc and MAPS[sc.mapID] or false end

-- this canvas scale as OpenMap's zoom (times the whole world fitting the view), so its settings
-- mean the same yards here; nil until its world is built
local function ZoomOf(scale)
	local W, H = S.Size()
	if not W or not H then return end
	if not yardK then
		local u0 = S.FromYards(1, 0, 0)
		local u1 = S.FromYards(1, 0, 1000)
		if not u0 or not u1 or u0 == u1 then return end
		yardK = math.abs(u1 - u0) / 1000                     -- world (0..1) a yard
	end
	local fit = math.min(sc:GetWidth() / W, sc:GetHeight() / H)
	local cw = canvas and canvas:GetWidth()
	if fit <= 0 or not cw or cw <= 0 then return end
	local pxPerYard = scale * cw / YW
	return pxPerYard / (yardK * W) / fit
end

-- Close.lua's mix: the settings' strength from their zoom, taking over toward their most at the deepest
local function Mix(zoom)
	local d = mod.db
	if not d or not d.minimap or not db.enabled then return 0 end
	local base, most = d.minimapMix or 0, d.minimapDeep or 1
	local from = d.minimapFrom or MINI_FADE[1]
	local k = from / MINI_FADE[1]
	local mix = math.min(base, most)
	if from > MINI_FROM_LEAST then
		miniFade[1], miniFade[2] = MINI_FADE[1] * k, MINI_FADE[2] * k
		mix = mix * Smooth(zoom, miniFade)
	end
	if base > 0 then
		local late = math.max(1, k)
		deepFade[1], deepFade[2] = DEEP_FADE[1] * late, DEEP_FADE[2] * late
		mix = mix + (most - mix) * Smooth(zoom, deepFade)
	end
	return mix
end

local function BuildCaves(level)
	under = CreateFrame("Frame", nil, canvas)
	under:SetAllPoints(canvas)
	under:SetFrameLevel(level + 10)
	dim = under:CreateTexture(nil, "BACKGROUND")
	dim:SetColorTexture(0.05, 0.035, 0.02, 1)
	dim:SetAllPoints(under)
	dim:Hide()
	for i, c in ipairs(Z.CAVES or {}) do
		local f = CreateFrame("Frame", nil, under)
		f:SetAllPoints(under)
		f:SetFrameLevel(level + 11 + i)
		f:Hide()
		-- its box on the canvas (0..1): east is -Y, south is -X
		local cave = { frame = f, pics = {},
			l = (MAX_Y - c[4]) / YW, r = (MAX_Y - c[2]) / YW, t = (MAX_X - c[3]) / XH, b = (MAX_X - c[1]) / XH }
		local p = c[5]
		local n = #p / 7
		for k = 1, n do
			local j = (k - 1) * 7
			local tex = f:CreateTexture(nil, "ARTWORK", nil, math.min(7, math.floor((k - 1) * 16 / n) - 8))
			tex:SetTexture(p[j + 1], "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE", "TRILINEAR")
			tex:SetTexCoord(0, p[j + 6], p[j + 7], 1)
			tex:SetRotation(p[j + 5])
			tex:SetDesaturation(MINI_DESAT)
			tex:SetVertexColor(PAPER[1], PAPER[2], PAPER[3])
			tex.cx, tex.cy, tex.side = (MAX_Y - p[j + 3]) / YW, (MAX_X - p[j + 2]) / XH, p[j + 4]
			cave.pics[k] = tex
		end
		caves[i] = cave
	end
	under:Hide()
end

local function Build()
	if frame then return end
	canvas = map:GetCanvas()
	frame = CreateFrame("Frame", nil, canvas)
	frame:SetAllPoints(canvas)
	local fl = map.GetPinFrameLevelsManager and map:GetPinFrameLevelsManager()
	local ok, level = false, nil
	if fl then ok, level = pcall(fl.GetValidFrameLevel, fl, "PIN_FRAME_LEVEL_OPENMAP_STITCH") end
	level = ok and level or canvas:GetFrameLevel() + 1
	frame:SetFrameLevel(level)
	mask = frame:CreateMaskTexture()
	mask:SetTexture(MASK, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
	for key, fid in pairs(Z.TILES) do
		local tex = frame:CreateTexture(nil, "ARTWORK")
		tex:SetTexture(fid, nil, nil, "LINEAR")
		tex:SetDesaturation(MINI_DESAT)
		tex:SetVertexColor(TINT[1], TINT[2], TINT[3])
		tex:AddMaskTexture(mask)
		tex.col, tex.row = math.floor(key / 64), key % 64
		textures[#textures + 1] = tex
	end
	BuildCaves(level)
	frame:SetScript("OnUpdate", function() Z.Refresh() end)
	frame:Hide()
end

-- a place on the canvas, in tiles
local function Place(region, col0, row0, col1, row1, w, h)
	local l = (MAX_Y - (32 - col0) * TILE) / YW * w
	local r = (MAX_Y - (32 - col1) * TILE) / YW * w
	local t = (MAX_X - (32 - row0) * TILE) / XH * h
	local b = (MAX_X - (32 - row1) * TILE) / XH * h
	region:ClearAllPoints()
	region:SetPoint("TOPLEFT", frame, "TOPLEFT", l, -t)
	region:SetSize(r - l, b - t)
end

local function Layout()
	local w, h = canvas:GetWidth(), canvas:GetHeight()
	if not w or w <= 0 or not h or h <= 0 or (w == laidW and h == laidH) then return end
	laidW, laidH = w, h
	Place(mask, COL0, ROW0, COL1, ROW1, w, h)
	for _, tex in ipairs(textures) do Place(tex, tex.col, tex.row, tex.col + 1, tex.row + 1, w, h) end
	local perYard = w / YW
	for _, cave in ipairs(caves) do
		for _, tex in ipairs(cave.pics) do
			tex:ClearAllPoints()
			tex:SetPoint("CENTER", cave.frame, "TOPLEFT", tex.cx * w, -tex.cy * h)
			tex:SetSize(tex.side * perYard, tex.side * perYard)
		end
	end
end

-- Close.lua's Surface: every cave in view by how much of the view it fills, once the zoom is deep
-- enough; the land above dims for the one you're centred on only
local function UpdateCaves(scale, zoom)
	local u, v = sc:GetCurrentScrollX(), sc:GetCurrentScrollY()
	local focus = 0
	local on = db.caves and zoom and u and v
	local hu, hv
	if on then
		hu = sc:NormalizeHorizontalSize(sc:GetWidth() * 0.5 / scale)
		hv = sc:NormalizeVerticalSize(sc:GetHeight() * 0.5 / scale)
	end
	for _, cave in ipairs(caves) do
		local tz = 0
		if on and cave.r > u - hu and cave.l < u + hu and cave.b > v - hv and cave.t < v + hv then
			local fill = math.min(2 * hu / (cave.r - cave.l), 2 * hv / (cave.b - cave.t))
			tz = (1 - Smooth(fill, UNDER_RANGE)) * Smooth(zoom, UNDER_ZOOM)
		end
		if tz > 0.01 then
			local off = math.max(math.abs((cave.l + cave.r) / 2 - u) / hu, math.abs((cave.t + cave.b) / 2 - v) / hv)
			focus = math.max(focus, tz * (1 - Smooth(off, FOCUS_RANGE)))
			cave.frame:SetAlpha(tz)
			cave.frame:Show()
		else
			cave.frame:Hide()
		end
	end
	if focus > 0.01 then
		dim:SetAlpha(DIM * focus)
		dim:Show()
	else
		dim:Hide()
	end
end

-- the zoom levels, from the least to `top`
local function SetLevels(top)
	local out, s = {}, zoomBase
	while s < top do
		out[#out + 1] = { scale = s, layerIndex = 1 }
		s = s * ZOOM_STEP
	end
	out[#out + 1] = { scale = top, layerIndex = 1 }
	sc.zoomLevels = out
	zoomNow = top
end

-- with the cursor over a cave the wheel goes on in, till its map fills the view; off it, back to the
-- deepest (zooming in never takes it out: not under where the view is now)
local function UpdateDepth(scale)
	if not zoomBase then return end
	local want = zoomTop
	local x, y
	if db.caves and map.GetNormalizedCursorPosition then x, y = map:GetNormalizedCursorPosition() end
	if x and y then
		local cw, ch = canvas:GetWidth(), canvas:GetHeight()
		local area
		for _, cave in ipairs(caves) do
			local cu, cv = cave.r - cave.l, cave.b - cave.t
			local mu, mv = cu * CAVE_MARGIN, cv * CAVE_MARGIN
			if x > cave.l - mu and x < cave.r + mu and y > cave.t - mv and y < cave.b + mv and (not area or cu * cv < area) then
				area = cu * cv
				local fit = math.min(sc:GetWidth() / (cu * cw), sc:GetHeight() / (cv * ch)) * CAVE_FILL
				want = math.max(zoomTop, math.min(fit, zoomTop * CAVE_DEEPER))
			end
		end
	end
	want = math.max(want, scale)
	if math.abs(want - zoomNow) > 1e-3 then SetLevels(want) end
end

function Z.Refresh(force)
	if not frame then return end
	local scale = sc:GetCanvasScale()
	local zoom
	if force or scale ~= lastScale then
		lastScale = scale
		Layout()
		zoom = ZoomOf(scale)
		frame:SetAlpha(zoom and Mix(zoom) or 0)
		Z.zoom = zoom
	end
	-- (the caves go by the view's centre too: a pan moves it, so every frame)
	UpdateCaves(scale, Z.zoom)
	UpdateDepth(scale)
	if not Z.reopening and map:IsShown() then
		local x, y = sc:GetCurrentScrollX(), sc:GetCurrentScrollY()
		local t = Z.track or {}
		t[1], t[2], t[3] = scale, x, y
		Z.track = t
	end
end

-- more zoom levels than Blizzard's one, as far as OpenMap's Deepest zoom goes here
local function ZoomLevels()
	local levels = sc.zoomLevels
	local base = levels and levels[1] and levels[1].scale
	if not base or base <= 0 then return end
	local zoom = ZoomOf(base)
	local most = mod.db and mod.db.maxZoom
	local factor = (zoom and most) and most / zoom or FALLBACK_FACTOR
	factor = math.max(2, math.min(MOST_FACTOR, factor))
	zoomBase, zoomTop = base, base * factor
	SetLevels(zoomTop)
	sc.baseScale = sc.baseScale or base
end

local function WheelOn()
	if OnIsle() and sc.SetMouseWheelZoomMode and MAP_CANVAS_MOUSE_WHEEL_ZOOM_BEHAVIOR_FULL then
		sc:SetMouseWheelZoomMode(MAP_CANVAS_MOUSE_WHEEL_ZOOM_BEHAVIOR_FULL)
	end
end

local function OnCreateZoomLevels()
	if not OnIsle() then
		if frame then
			frame:Hide()
			under:Hide()
		end
		return
	end
	Build()
	ZoomLevels()
	laidW, lastScale = nil, nil
	frame:Show()
	under:Show()
	Z.Refresh(true)
	-- (OpenMap's own hook on this runs too, and puts Blizzard's wheel mode back: after it)
	WheelOn()
	C_Timer.After(0, WheelOn)
end

local function Setup()
	map = _G.WorldMapFrame
	sc = map and map.ScrollContainer
	if not (sc and sc.CreateZoomLevels and map.GetCanvas) then
		map = nil
		Say(L.missing)
		return
	end
	hooksecurefunc(sc, "CreateZoomLevels", OnCreateZoomLevels)
	map:HookScript("OnHide", function() Z.OnHidden() end)
	map:HookScript("OnShow", function() Z.OnShown() end)
end

local function Toggle(on)
	db.enabled = on
	Z.Refresh(true)
end

local function ToggleCaves(on)
	db.caves = on
	Z.Refresh(true)
end

local function Open()
	if InCombatLockdown() then return Say(L.combat) end
	if not map:IsShown() and _G.ToggleWorldMap then _G.ToggleWorldMap() end
	if not (mod.OpenAwayMap and mod.OpenAwayMap(2521)) then map:SetMapID(2521) end
end

-- the view put at once, as OpenMap's SetView (WorldMap.lua) does
local function PutView(scale, u, v)
	SetLevels(math.max(zoomTop, scale))
	if sc.CalculateScrollExtents and sc.Child and sc.SetNormalizedHorizontalScroll then
		sc.currentScale, sc.targetScale, sc.zoomTarget = scale, scale, scale
		sc.Child:SetScale(scale)
		sc:CalculateScrollExtents()
		u = math.max(sc.scrollXExtentsMin, math.min(sc.scrollXExtentsMax, u))
		v = math.max(sc.scrollYExtentsMin, math.min(sc.scrollYExtentsMax, v))
		sc.targetScrollX, sc.targetScrollY, sc.currentScrollX, sc.currentScrollY = u, v, u, v
		sc:SetNormalizedHorizontalScroll(u)
		sc:SetNormalizedVerticalScroll(v)
		if map.OnCanvasScaleChanged then map:OnCanvasScaleChanged() end
	elseif sc.InstantPanAndZoom then
		sc:InstantPanAndZoom(scale, u, v)
	end
	Z.Refresh(true)
end

-- the view at a place on the isle's map (percent, as the map's coordinates read), as deep as the zoom
-- goes there: to the cave, on one
local function ViewAt(x, y)
	if not OnIsle() or not zoomBase then return end
	local u, v = x / 100, y / 100
	local scale, area = zoomTop, nil
	local cw, ch = canvas:GetWidth(), canvas:GetHeight()
	if db.caves then
		for _, cave in ipairs(caves) do
			local cu, cv = cave.r - cave.l, cave.b - cave.t
			local mu, mv = cu * CAVE_MARGIN, cv * CAVE_MARGIN
			if u > cave.l - mu and u < cave.r + mu and v > cave.t - mv and v < cave.b + mv and (not area or cu * cv < area) then
				area = cu * cv
				local fit = math.min(sc:GetWidth() / (cu * cw), sc:GetHeight() / (cv * ch)) * CAVE_FILL
				scale = math.max(zoomTop, math.min(fit, zoomTop * CAVE_DEEPER))
			end
		end
	end
	PutView(scale, u, v)
end

-- OpenMap's "When reopening the map" (the menu's Map opening), which it only does on its stitched map:
-- its choice, read, done here for the isle's view. "player" is Blizzard's own opening: the whole isle.
-- The view is kept every frame the map's up (Z.Track): by the time the map's OnHide reaches us the
-- game may have reset it already. It stops being kept from the closing on: the game's own OnShow, which
-- resets the view and rebuilds the zoom levels (so Z.Refresh), runs before our hook on it.
function Z.OnHidden()
	reopenTry = reopenTry + 1
	Z.reopening = true
	if OnIsle() and zoomBase and Z.track then saved = { Z.track[1], Z.track[2], Z.track[3] } end
end

local function PlayerAt()
	local ok, x, y = pcall(function()
		local pos = C_Map.GetPlayerMapPosition(sc.mapID, "player")
		if not pos then return end
		local px, py = pos:GetXY()
		if px and py and (px > 0 or py > 0) then return px, py end
	end)
	if ok then return x, y end
end

-- where the reopening puts the view, by the menu's choice; nil: as Blizzard opens it
local function ReopenTarget()
	if not saved or not saved[2] or not saved[3] then return end
	local mode = mod.db and mod.db.reopenView or "player"
	local scale, x, y = saved[1], saved[2], saved[3]
	if mode == "always" or mode == "zone" then return scale, x, y end
	if mode == "zoom" then
		local px, py = PlayerAt()
		return scale, px or x, py or y
	end
	if mode == "visible" then
		local px, py = PlayerAt()
		if px and math.abs(px - x) <= sc:NormalizeHorizontalSize(sc:GetWidth() * 0.5 / scale)
			and math.abs(py - y) <= sc:NormalizeVerticalSize(sc:GetHeight() * 0.5 / scale) then
			return scale, x, y
		end
	end
end

-- after Blizzard's zoom reset on opening and the map it puts up, whichever frames those come on: put
-- again if something has moved it, and not kept as the view until it's done
local REOPEN_TRIES = { 0, 0.05, 0.15, 0.4 }
function Z.OnShown()
	Z.reopening = true
	reopenTry = reopenTry + 1
	local try = reopenTry
	local scale, x, y
	for i, delay in ipairs(REOPEN_TRIES) do
		C_Timer.After(delay, function()
			if try ~= reopenTry then return end      -- (closed or opened again since)
			if map:IsShown() and OnIsle() and zoomBase then
				if i == 1 then scale, x, y = ReopenTarget() end
				if scale and (math.abs(sc:GetCanvasScale() - scale) > 1e-3
					or math.abs((sc:GetCurrentScrollX() or 0) - x) > 1e-3 or math.abs((sc:GetCurrentScrollY() or 0) - y) > 1e-3) then
					PutView(scale, x, y)
				end
			end
			if i == #REOPEN_TRIES then Z.reopening = false end
		end)
	end
end

-- /zephras view: what the reopening has to go on
function Z.Report()
	local base = zoomBase or 1
	Say(string.format("%s | %s | now x%.1f | kept %s | closed %s | player %s", tostring(sc.mapID), tostring(mod.db and mod.db.reopenView),
		sc:GetCanvasScale() / base, Z.track and string.format("x%.1f", Z.track[1] / base) or "-",
		saved and string.format("x%.1f", saved[1] / base) or "-", (PlayerAt()) and "on map" or "not on map"))
end

local function GoTo(x, y)
	if InCombatLockdown() then return Say(L.combat) end
	if map:IsShown() and OnIsle() then return ViewAt(x, y) end
	Open()
	C_Timer.After(0, function() ViewAt(x, y) end)   -- (once the map has changed)
end

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:SetScript("OnEvent", function(self, _, name)
	if name ~= ADDON then return end
	self:UnregisterEvent("ADDON_LOADED")
	OpenMapZephrasDB = OpenMapZephrasDB or {}
	db = OpenMapZephrasDB
	if db.enabled == nil then db.enabled = true end
	if db.caves == nil then db.caves = true end
	if OM.RegisterMenuToggle then
		pcall(OM.RegisterMenuToggle, ADDON, {
			id = "minimap", label = L.name, tab = "look", section = L.section,
			icon = "Interface\\Icons\\INV_Misc_Map_01",
			get = function() return db.enabled end,
			set = Toggle,
		})
		pcall(OM.RegisterMenuToggle, ADDON, {
			id = "caves", label = L.caves, tab = "look", section = L.section,
			icon = "Interface\\Icons\\INV_Misc_Spyglass_02",
			get = function() return db.caves end,
			set = ToggleCaves,
		})
	end
	if _G.WorldMapFrame then Setup() else EventUtil.ContinueOnAddOnLoaded("Blizzard_WorldMap", Setup) end
end)

SLASH_OPENMAPZEPHRAS1 = "/zephras"
SlashCmdList.OPENMAPZEPHRAS = function(msg)
	if not map then return Say(L.missing) end
	msg = (msg or ""):lower()
	local px, py = msg:match("^%s*(%d+[%.,]?%d*)%s+(%d+[%.,]?%d*)%s*$")
	if px then
		GoTo(tonumber((px:gsub(",", "."))), tonumber((py:gsub(",", "."))))
	elseif msg:find("toggle") then
		Toggle(not db.enabled)
		Say(db.enabled and L.on or L.off)
	elseif msg:find("view") then
		Z.Report()
	elseif msg:find("cave") then
		ToggleCaves(not db.caves)
		Say(db.caves and L.cavesOn or L.cavesOff)
	else
		Open()
	end
end
