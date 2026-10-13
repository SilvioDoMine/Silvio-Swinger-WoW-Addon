-- SilvioSwinger: indicador simples de seal twisting para Paladino (cliente 2.4.3)
-- Ideia: SoC ativo -> nos últimos ~0.4s antes do swing, troca para SoB/SoR/Martyr.
-- O swing que cai logo depois proca os dois selos. Depois: Julgamento (fora do GCD) + SoC de novo.

local ADDON = "SilvioSwinger"
local VERSION = GetAddOnMetadata(ADDON, "Version") or "?"  -- vem do .toc (## Version)

local defaults = {
	window   = 0.40,  -- quanto antes do swing o twist ainda funciona (s)
	buffer   = 0.05,  -- margem extra somada à latência (s)
	csSlack  = 0.10,  -- folga exigida para encaixar um Crusader Strike antes da janela (s)
	judge    = true,  -- sugerir Julgamento depois do twist
	sound    = true,  -- som quando a janela de twist abre
	lowMana  = 0.10,  -- avisa quando a mana estiver abaixo disso (fração)
	dmgMsg   = true,  -- "TWIST DAMAGE: X" no topo da tela
	breakdown = true, -- mostra hit + SoC + SoB na mensagem
	scale    = 1.0,
	locked   = false,
	hidden   = false,
	locale   = "auto", -- "auto" = idioma do cliente; ou um código de Locales/ (ex.: "ptBR")
	point    = { "CENTER", "UIParent", "CENTER", 0, -160 },
}

local db
local playerGUID
local BuildOptions, SetHidden  -- definidas lá embaixo, junto do painel de opções

-- ---------------------------------------------------------------------------
-- Localização: cada arquivo em Locales/ registra SilvioSwingerLocales[código].
-- L recebe o inglês e, por cima, o idioma escolhido (texto faltando = inglês).
-- ---------------------------------------------------------------------------
local LOCALES = SilvioSwingerLocales or {}
local ALIASES = { enGB = "enUS", esMX = "esES" }
local L = {}

local function ResolveLocale(code)
	code = ALIASES[code] or code
	if LOCALES[code] then return code end
	return "enUS"
end

local function ApplyLocale()
	local code = ResolveLocale(db.locale ~= "auto" and db.locale or GetLocale())
	for k in pairs(L) do L[k] = nil end
	for k, v in pairs(LOCALES.enUS) do L[k] = v end
	for k, v in pairs(LOCALES[code]) do L[k] = v end
	L._code = code
end

-- Códigos disponíveis, ordenados pelo nome do idioma
local function LocaleCodes()
	local codes = {}
	for code in pairs(LOCALES) do table.insert(codes, code) end
	table.sort(codes, function(a, b) return LOCALES[a]._name < LOCALES[b]._name end)
	return codes
end

local function OnOff(v)
	return v and L.ON or L.OFF
end

-- Nomes localizados via spell ID (funciona em qualquer idioma do cliente)
local function SpellName(id)
	local name, _, icon = GetSpellInfo(id)
	return name, icon
end

local S = {}           -- S.COMMAND = { name=, icon= } etc
local function Def(key, ...)
	for i = 1, select("#", ...) do
		local name, icon = SpellName((select(i, ...)))
		if name then
			S[key] = { name = name, icon = icon }
			return
		end
	end
end
Def("COMMAND", 20375)
Def("BLOOD", 31892)
Def("MARTYR", 348700)       -- só existe em TBC Classic; em 2.4.3 normalmente é nil
Def("RIGHTEOUS", 20154, 21084)
Def("CS", 35395)
Def("JUDGE", 20271)

local known = {}           -- nomes de magias no spellbook
local twistKey             -- "BLOOD", "MARTYR" ou "RIGHTEOUS"

local function ScanSpellbook()
	for k in pairs(known) do known[k] = nil end
	local i = 1
	while true do
		local name = GetSpellName(i, BOOKTYPE_SPELL)
		if not name then break end
		known[name] = true
		i = i + 1
	end
	twistKey = nil
	for _, k in ipairs({ "BLOOD", "MARTYR", "RIGHTEOUS" }) do
		if S[k] and known[S[k].name] then twistKey = k break end
	end
end

local function Knows(key)
	return S[key] and known[S[key].name]
end

-- ---------------------------------------------------------------------------
-- Estado do swing timer
-- ---------------------------------------------------------------------------
local speed = 3.5          -- velocidade atual da arma (já com haste)
local lastSwing = 0        -- GetTime() do último swing
local nextSwing = 0        -- GetTime() previsto do próximo swing
local attacking = false    -- auto-attack ligado
local casting = false      -- conjurando magia com tempo de cast
local gcdDuration = 1.5

-- Streak / avaliação do twist
local twistCastAt          -- quando o selo de twist foi conjurado com SoC ativo
local streak, best = 0, 0
local lastResult, lastResultAt = nil, 0

local function Latency()
	local _, _, lat = GetNetStats()
	return (lat or 0) / 1000 + db.buffer
end

local function CooldownLeft(name)
	if not name or not known[name] then return nil end
	local start, dur = GetSpellCooldown(name)
	if not start or start == 0 then return 0 end
	return math.max(0, start + dur - GetTime()), dur
end

-- GCD: lê o cooldown de um selo qualquer conhecido
local function GCDLeft()
	local ref = (Knows("COMMAND") and S.COMMAND.name) or (Knows("RIGHTEOUS") and S.RIGHTEOUS.name)
	local left, dur = CooldownLeft(ref)
	if not left then return 0 end
	if dur and dur > 0 and dur <= 1.5 then gcdDuration = dur end
	if dur and dur > 1.5 then return 0 end -- não é GCD
	return left
end

-- Qual selo está ativo: "COMMAND", twistKey, "OTHER" ou nil
local function CurrentSeal()
	local found
	local i = 1
	while true do
		local name = UnitBuff("player", i)
		if not name then break end
		if S.COMMAND and name == S.COMMAND.name then return "COMMAND" end
		for _, k in ipairs({ "BLOOD", "MARTYR", "RIGHTEOUS" }) do
			if S[k] and name == S[k].name then found = k end
		end
		i = i + 1
	end
	return found
end

-- ---------------------------------------------------------------------------
-- Dano do twist (estilo "windfury calculator")
-- Junta num "pacote" tudo que cai junto com o swing: hit branco, ataques extras
-- e procs de selo. Fecha o pacote 0.4s depois e, se foi twist, mostra no topo.
-- ---------------------------------------------------------------------------
local SHORT = { COMMAND = "SoC", BLOOD = "SoB", MARTYR = "SoM", RIGHTEOUS = "SoR" }
local SEAL_ORDER = { "COMMAND", "BLOOD", "MARTYR", "RIGHTEOUS" }
-- pacote atual: { start, seen, white = {dmg, n, extra}, seals = {key = {dmg, n}}, twist }
--   start: timestamp do combat log do primeiro evento (hora real no servidor)
--   seen:  GetTime() do último evento que chegou (hora no cliente)
--   white.extra: quantos dos golpes brancos foram ataques extras
local hit
local twistStats = { count = 0, total = 0, biggest = 0 }

-- O servidor manda os eventos em lotes (spell batching): coisas que aconteceram juntas
-- podem chegar no cliente com mais de 0.4s de diferença. Por isso o pacote é agrupado
-- pelo timestamp do combat log, e só fecha depois de um tempo sem chegar nada.
local BUNDLE_SPAN = 0.4    -- eventos até 0.4s depois do primeiro (hora do servidor) são do mesmo swing
local BUNDLE_IDLE = 1.0    -- fecha o pacote 1s (hora do cliente) depois do último evento
local curTs = 0            -- timestamp do evento do combat log sendo tratado agora

-- Ataques extras anunciados no combat log (SPELL_EXTRA_ATTACKS: Reckoning, Windfury Totem,
-- Hand of Justice...) que ainda não caíram: { name, left, at }. O golpe extra vem logo depois.
local pendingExtras = {}

local function SealKeyByName(name)
	for _, k in ipairs(SEAL_ORDER) do
		if S[k] and S[k].name == name then return k end
	end
end

-- Soma dano e conta um golpe numa entrada { dmg, n }
local function Add(entry, dmg)
	entry.dmg = entry.dmg + (dmg or 0)
	entry.n = entry.n + 1
end

-- Consome um ataque extra anunciado; anúncios com mais de 1s sem golpe são descartados
local function TakeExtra()
	local now = GetTime()
	while pendingExtras[1] do
		local e = pendingExtras[1]
		if now - e.at > 1 then
			table.remove(pendingExtras, 1)
		else
			e.left = e.left - 1
			if e.left <= 0 then table.remove(pendingExtras, 1) end
			return e.name
		end
	end
end

-- ---------------------------------------------------------------------------
-- Modo diagnóstico (/silvio debug): escreve no chat cada evento do combat log que
-- passa pelo pacote do twist e como foi classificado. Saída técnica, sem tradução.
-- Não é salvo: desliga no /reload.
-- ---------------------------------------------------------------------------
local debugOn = false
local debugT0 = 0          -- timestamp do combat log do primeiro evento do grupo atual

local function DebugLine(text)
	DEFAULT_CHAT_FRAME:AddMessage("|cff999999[SS debug]|r " .. text)
end

-- ts: timestamp do combat log (tem milissegundos, ao contrário do GetTime() do frame)
local function DebugEvent(ts, subEvent, spell, target, value, crit, outcome)
	if not debugOn then return end
	ts = ts or GetTime()
	if ts - debugT0 > 1 then
		debugT0 = ts
		DebugLine("|cff666666--------|r")
	end
	DebugLine(string.format("+%.3f %s %s-> %s %s%s  |cffffff00%s|r",
		ts - debugT0, subEvent, spell and (spell .. " ") or "", target or "?",
		tostring(value or ""), crit and " CRIT" or "", outcome))
end

local function Part(label, entry)
	return string.format("%s %d (%d)", label, entry.dmg, entry.n)
end

local function FlushHit(force)
	if not hit then return end
	if not force and GetTime() - hit.seen < BUNDLE_IDLE then return end
	local b = hit
	hit = nil

	local nSeals, sealDmg = 0, 0
	for _, e in pairs(b.seals) do
		nSeals = nSeals + 1
		sealDmg = sealDmg + e.dmg
	end
	-- twist = dois selos procaram juntos, ou o twist foi feito no tempo certo
	if nSeals < 2 and not b.twist then
		if debugOn then DebugLine(string.format("bundle discarded: not a twist (%d seal(s), timed twist: no)", nSeals)) end
		return
	end

	local total = b.white.dmg + sealDmg
	if total <= 0 then return end
	if debugOn then
		DebugLine(string.format("bundle = twist, total %d (%d hit(s) incl. %d extra, %d seal(s), timed twist: %s)",
			total, b.white.n, b.white.extra, nSeals, b.twist and "yes" or "no"))
	end
	twistStats.count = twistStats.count + 1
	twistStats.total = twistStats.total + total
	if total > twistStats.biggest then twistStats.biggest = total end

	if db.dmgMsg then
		local text = string.format(L.DMG_TOTAL, total)
		if db.breakdown then
			-- "hit 2233 (2) + SoC 975 (1) + SoB 1857 (3) [1 Extra]": entre parênteses, quantos
			-- golpes/procs de cada um caíram. Ataque extra (de qualquer fonte) conta como hit,
			-- os procs de selo que ele causa já entram em cada selo, e o total de extras vai no fim.
			local parts = {}
			if b.white.n > 0 then table.insert(parts, Part(L.DMG_HIT, b.white)) end
			for _, k in ipairs(SEAL_ORDER) do
				if b.seals[k] then table.insert(parts, Part(SHORT[k], b.seals[k])) end
			end
			text = text .. " = " .. table.concat(parts, " + ")
			if b.white.extra > 0 then
				text = text .. " " .. string.format(L.DMG_EXTRA, b.white.extra)
			end
		end
		UIErrorsFrame:AddMessage(text, 0.25, 0.6, 1.0, 1.0, UIERRORS_HOLD_TIME)
	end
end

-- Pacote do evento atual (curTs). Um evento longe demais do início do pacote aberto
-- é de outro swing: fecha o anterior e abre um novo.
local function HitBucket()
	if hit and curTs - hit.start > BUNDLE_SPAN then FlushHit(true) end
	if not hit then
		hit = { start = curTs, white = { dmg = 0, n = 0, extra = 0 }, seals = {} }
	end
	hit.seen = GetTime()
	return hit
end

local function OnSwing()
	local now = GetTime()
	-- Ataques extras (Hand of Justice, Windfury) não reiniciam o timer
	if now - lastSwing < speed * 0.5 and nextSwing > now then return end

	if twistCastAt then
		local gap = now - twistCastAt
		if gap <= db.window + 0.1 then
			streak = streak + 1
			if streak > best then best = streak end
			lastResult = "RESULT_PERFECT"
			HitBucket().twist = true
		else
			streak = 0
			lastResult = "RESULT_EARLY"
		end
		lastResultAt = now
		twistCastAt = nil
	end

	lastSwing = now
	nextSwing = now + speed
end

local function OnSpeedChanged()
	local new = UnitAttackSpeed("player")
	if not new or new <= 0 then return end
	local now = GetTime()
	if nextSwing > now and speed > 0 then
		-- reescala o tempo restante (Bloodlust, Drums, Haste Potion...)
		nextSwing = now + (nextSwing - now) * new / speed
	end
	speed = new
end

-- ---------------------------------------------------------------------------
-- Interface
-- ---------------------------------------------------------------------------
local W, BAR_H, ICON = 220, 14, 44

local f = CreateFrame("Frame", "SilvioSwingerFrame", UIParent)
f:SetWidth(W) f:SetHeight(ICON + BAR_H + 34)
f:SetMovable(true) f:EnableMouse(true) f:RegisterForDrag("LeftButton")
-- Só move com Shift + arrastar (e se não estiver travado), pra não mover sem querer
f:SetScript("OnDragStart", function(self)
	if not db.locked and IsShiftKeyDown() then self:StartMoving() end
end)
f:SetScript("OnDragStop", function(self)
	self:StopMovingOrSizing()
	local p, _, rp, x, y = self:GetPoint()
	db.point = { p, "UIParent", rp, x, y }
end)

local function MakeIcon(size)
	local t = f:CreateTexture(nil, "ARTWORK")
	t:SetWidth(size) t:SetHeight(size)
	t:SetTexCoord(0.07, 0.93, 0.07, 0.93)
	return t
end

local nowIcon = MakeIcon(ICON)
nowIcon:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
local nextIcon = MakeIcon(ICON * 0.65)
nextIcon:SetPoint("BOTTOMLEFT", nowIcon, "BOTTOMRIGHT", 6, 0)
nextIcon:SetAlpha(0.6)

local glow = f:CreateTexture(nil, "OVERLAY")
glow:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
glow:SetBlendMode("ADD")
glow:SetWidth(ICON * 1.8) glow:SetHeight(ICON * 1.8)
glow:SetPoint("CENTER", nowIcon, "CENTER")

local msg = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
msg:SetPoint("TOPLEFT", nextIcon, "TOPRIGHT", 8, 4)
msg:SetJustifyH("LEFT")
local sub = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
sub:SetPoint("TOPLEFT", msg, "BOTTOMLEFT", 0, -2)
sub:SetJustifyH("LEFT")

-- Barra de swing
local bar = CreateFrame("Frame", nil, f)
bar:SetWidth(W) bar:SetHeight(BAR_H)
bar:SetPoint("TOPLEFT", nowIcon, "BOTTOMLEFT", 0, -6)
local bg = bar:CreateTexture(nil, "BACKGROUND")
bg:SetAllPoints() bg:SetTexture(0, 0, 0, 0.6)

local fill = bar:CreateTexture(nil, "BORDER")
fill:SetPoint("TOPLEFT") fill:SetPoint("BOTTOMLEFT")
fill:SetTexture(0.8, 0.8, 0.8, 0.8)

local zoneTwist = bar:CreateTexture(nil, "ARTWORK")   -- janela verde
zoneTwist:SetTexture(0.1, 0.9, 0.1, 0.55)
zoneTwist:SetHeight(BAR_H)
local zoneDead = bar:CreateTexture(nil, "ARTWORK")    -- latência: tarde demais
zoneDead:SetTexture(0.9, 0.1, 0.1, 0.65)
zoneDead:SetPoint("TOPRIGHT") zoneDead:SetPoint("BOTTOMRIGHT")
local gcdLine = bar:CreateTexture(nil, "OVERLAY")     -- último momento p/ SoC/CS sem atrapalhar twist
gcdLine:SetTexture(1, 0.8, 0, 1)
gcdLine:SetWidth(2) gcdLine:SetHeight(BAR_H)

local barText = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
barText:SetPoint("CENTER")

local streakText = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
streakText:SetPoint("TOPLEFT", bar, "BOTTOMLEFT", 0, -3)
local resultText = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
resultText:SetPoint("TOPRIGHT", bar, "BOTTOMRIGHT", 0, -3)

local QUESTION = "Interface\\Icons\\INV_Misc_QuestionMark"
local function SetIcon(tex, key)
	if key and S[key] then
		tex:SetTexture(S[key].icon) tex:Show()
	elseif key == false then
		tex:Hide()
	else
		tex:SetTexture(QUESTION) tex:Show()
	end
end

-- ---------------------------------------------------------------------------
-- Lógica de recomendação
-- ---------------------------------------------------------------------------
local soundPlayedFor = 0
-- Ping do minimapa: curto e fácil de ouvir no meio do combate
-- (o clique de checkbox de antes sumia no barulho da luta)
local TWIST_SOUND = "Sound\\Interface\\MapPing.wav"
local function PlayTwistSound()
	PlaySoundFile(TWIST_SOUND)
end
local lastCommandSeen = 0  -- último instante em que o SoC estava ativo

local function Recommend()
	local now = GetTime()
	local seal = CurrentSeal()
	if seal == "COMMAND" then lastCommandSeen = now end
	local gcd = GCDLeft()
	local lat = Latency()
	local t = (attacking and nextSwing > now) and (nextSwing - now) or nil
	local csCD = Knows("CS") and CooldownLeft(S.CS.name) or nil
	local jCD = Knows("JUDGE") and CooldownLeft(S.JUDGE.name) or nil
	local tw = twistKey

	-- retorna: ícone agora, ícone próximo, chave do texto em L, cor {r,g,b}, brilho, argumento do texto
	-- (chave "SPELL" = o argumento já é o nome da magia, vindo do cliente)
	if not Knows("COMMAND") then
		return nil, false, "MSG_NO_COMMAND", { 1, 0.3, 0.3 }, false
	end

	-- Fora de combate / sem swing conhecido: só prepare o SoC
	if not t then
		if seal == "COMMAND" then
			return "COMMAND", tw or false, "MSG_READY", { 0.6, 1, 0.6 }, false
		end
		return "COMMAND", tw or false, "MSG_PREPARE", { 1, 0.82, 0 }, gcd == 0
	end

	if seal == "COMMAND" then
		if not tw then
			return "COMMAND", false, "MSG_NO_TWIST_SEAL", { 1, 0.5, 0 }, false
		end
		if t <= db.window and t > lat then
			if gcd <= t - lat then
				return tw, "JUDGE", "MSG_TWIST", { 0.2, 1, 0.2 }, true
			end
			return tw, "COMMAND", "MSG_GCD_LOST", { 1, 0.3, 0.3 }, false
		elseif t <= lat then
			return tw, "COMMAND", "MSG_TOO_LATE", { 1, 0.3, 0.3 }, false
		end
		-- Ainda longe da janela: dá pra encaixar Crusader Strike?
		local toWindow = t - db.window
		if csCD and csCD <= gcd and toWindow >= gcd + gcdDuration + db.csSlack then
			return "CS", tw, "SPELL", { 1, 0.82, 0 }, gcd == 0, S.CS.name
		end
		return tw, "JUDGE", "MSG_WAIT", { 0.8, 0.8, 0.8 }, false, toWindow
	end

	-- Selo de twist ativo (pós-swing) ou nenhum selo
	if seal == tw and db.judge and jCD and jCD == 0 then
		return "JUDGE", "COMMAND", "MSG_JUDGE_SOC", { 1, 0.82, 0 }, true
	end
	if gcd > 0 then
		return "COMMAND", false, "MSG_SOC_IN", { 0.8, 0.8, 0.8 }, false, gcd
	end
	return "COMMAND", tw or false, "SPELL", { 1, 0.82, 0 }, true, S.COMMAND.name
end

local function UpdateBar()
	local now = GetTime()
	local lat = Latency()
	local pxPerSec = W / speed
	local twW = math.min(W, db.window * pxPerSec)
	local deadW = math.min(twW, lat * pxPerSec)
	zoneTwist:ClearAllPoints()
	zoneTwist:SetPoint("TOPRIGHT", bar, "TOPRIGHT", -deadW, 0)
	zoneTwist:SetWidth(math.max(1, twW - deadW))
	zoneDead:SetWidth(math.max(1, deadW))

	local gcdX = W - (db.window + gcdDuration) * pxPerSec
	if gcdX > 0 then
		gcdLine:ClearAllPoints()
		gcdLine:SetPoint("TOPLEFT", bar, "TOPLEFT", gcdX, 0) gcdLine:Show()
	else
		gcdLine:Hide() -- arma rápida demais pra SoC + twist no mesmo swing
	end

	if attacking and nextSwing > now then
		local left = nextSwing - now
		fill:SetWidth(math.max(1, W * (1 - left / speed)))
		barText:SetText(string.format("%.2f / %.2f", left, speed))
	else
		fill:SetWidth(W)
		barText:SetText(attacking and L.BAR_READY or string.format("%.2f", speed))
	end
end

local acc = 0
f:SetScript("OnUpdate", function(self, elapsed)
	acc = acc + elapsed
	if acc < 0.02 then return end
	acc = 0

	FlushHit()

	local nowKey, nextKey, msgKey, color, shine, arg = Recommend()
	SetIcon(nowIcon, nowKey)
	SetIcon(nextIcon, nextKey)
	if msgKey == "SPELL" then
		msg:SetText(arg)
	else
		msg:SetText(string.format(L[msgKey], arg))
	end
	msg:SetTextColor(color[1], color[2], color[3])
	if shine then glow:Show() else glow:Hide() end

	if msgKey == "MSG_TWIST" and db.sound and soundPlayedFor ~= nextSwing then
		soundPlayedFor = nextSwing
		PlayTwistSound()
	end

	local mana, maxMana = UnitMana("player"), UnitManaMax("player")
	local lat = Latency()
	local info = string.format(L.LATENCY, lat * 1000)
	if maxMana > 0 and mana / maxMana < db.lowMana then
		info = "|cffff4040" .. L.LOW_MANA .. "|r  " .. info
	end
	sub:SetText(info)

	if twistStats.count > 0 then
		streakText:SetText(string.format(L.STREAK_AVG,
			streak, best, twistStats.total / twistStats.count))
	else
		streakText:SetText(string.format(L.STREAK, streak, best))
	end
	if lastResult and GetTime() - lastResultAt < 1.5 then
		resultText:SetText(L[lastResult])
		if lastResult == "RESULT_PERFECT" then resultText:SetTextColor(0.2, 1, 0.2)
		else resultText:SetTextColor(1, 0.3, 0.3) end
	else
		resultText:SetText("")
	end

	UpdateBar()
end)

-- ---------------------------------------------------------------------------
-- Eventos
-- ---------------------------------------------------------------------------
f:RegisterEvent("PLAYER_LOGIN")
f:SetScript("OnEvent", function(self, event, ...)
	if event == "PLAYER_LOGIN" then
		local _, class = UnitClass("player")
		if class ~= "PALADIN" then self:Hide() return end

		SilvioSwingerDB = SilvioSwingerDB or {}
		db = SilvioSwingerDB
		for k, v in pairs(defaults) do
			if db[k] == nil then db[k] = v end
		end
		ApplyLocale()
		playerGUID = UnitGUID("player")
		self:ClearAllPoints()
		self:SetPoint(unpack(db.point))
		self:SetScale(db.scale)
		BuildOptions()
		SetHidden(db.hidden)
		ScanSpellbook()
		OnSpeedChanged()

		self:RegisterEvent("SPELLS_CHANGED")
		self:RegisterEvent("UNIT_ATTACK_SPEED")
		self:RegisterEvent("PLAYER_ENTER_COMBAT")
		self:RegisterEvent("PLAYER_LEAVE_COMBAT")
		self:RegisterEvent("UNIT_SPELLCAST_START")
		self:RegisterEvent("UNIT_SPELLCAST_INTERRUPTED")
		self:RegisterEvent("UNIT_SPELLCAST_FAILED")
		self:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
		self:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")

	elseif event == "SPELLS_CHANGED" then
		ScanSpellbook()

	elseif event == "UNIT_ATTACK_SPEED" then
		if ... == "player" then OnSpeedChanged() end

	elseif event == "PLAYER_ENTER_COMBAT" then
		attacking = true
	elseif event == "PLAYER_LEAVE_COMBAT" then
		attacking = false
		twistCastAt = nil
		for i = #pendingExtras, 1, -1 do pendingExtras[i] = nil end
		FlushHit(true)

	elseif event == "UNIT_SPELLCAST_START" then
		if ... == "player" then casting = true end
	elseif event == "UNIT_SPELLCAST_INTERRUPTED" or event == "UNIT_SPELLCAST_FAILED" then
		if ... == "player" then casting = false end

	elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
		local unit, spell = ...
		if unit ~= "player" then return end
		if casting then
			-- magia com tempo de cast (Exorcism, Flash of Light...) reinicia o swing
			casting = false
			nextSwing = GetTime() + speed
		end
		-- Conjurou o selo de twist enquanto SoC estava ativo: avaliar no próximo swing
		local now = GetTime()
		if twistKey and spell == S[twistKey].name and now - lastCommandSeen < 0.3 then
			if now - lastSwing < 0.25 and lastSwing > 0 then
				streak = 0
				lastResult, lastResultAt = "RESULT_LATE", now
				twistCastAt = nil
			else
				twistCastAt = now
			end
		end

	elseif event == "COMBAT_LOG_EVENT_UNFILTERED" then
		local ts, subEvent, srcGUID, srcName, _, dstGUID, dstName = ...
		if srcGUID ~= playerGUID then
			-- No debug, mostra ataque extra que outra pessoa te deu (ex.: totem de um xamã)
			if debugOn and subEvent == "SPELL_EXTRA_ATTACKS" and dstGUID == playerGUID then
				DebugEvent(ts, subEvent, select(10, ...), dstName, select(12, ...), nil,
					"IGNORED: source is " .. tostring(srcName))
			end
			return
		end
		curTs = ts or 0
		-- Posições depois dos 8 campos base (2.4.3, sem "overkill"):
		-- SWING_DAMAGE: 9 amount ... 14 critical | SPELL_*: 10 spellName, 12 amount ... 17 critical
		if subEvent == "SWING_DAMAGE" or subEvent == "SWING_MISSED" then
			-- Golpe logo depois do swing anterior + ataque extra anunciado = é o golpe extra.
			-- Um swing normal nunca cai a menos de meia velocidade da arma do anterior.
			local extra = GetTime() - lastSwing < speed * 0.5 and TakeExtra()
			local outcome = extra and ("extra: " .. extra) or "hit"
			if subEvent == "SWING_DAMAGE" then
				local b = HitBucket()
				local dmg = select(9, ...)
				Add(b.white, dmg)
				if extra then b.white.extra = b.white.extra + 1 end
				DebugEvent(ts, subEvent, nil, dstName, dmg, select(14, ...), outcome)
			else
				DebugEvent(ts, subEvent, nil, dstName, select(9, ...), nil, outcome .. " (missed, not counted)")
			end
			OnSwing()
		elseif subEvent == "SPELL_EXTRA_ATTACKS" then
			table.insert(pendingExtras, {
				name = select(10, ...) or "?",
				left = select(12, ...) or 1,
				at = GetTime(),
			})
			DebugEvent(ts, subEvent, select(10, ...), dstName, select(12, ...), nil, "queued")
		elseif subEvent == "SPELL_DAMAGE" then
			local spell, amount = select(10, ...), select(12, ...)
			local key = SealKeyByName(spell)
			if dstGUID == playerGUID then
				-- o dano que o Seal of Blood causa em você
				DebugEvent(ts, subEvent, spell, dstName, amount, nil, "IGNORED: self")
			elseif key then
				local b = HitBucket()
				b.seals[key] = b.seals[key] or { dmg = 0, n = 0 }
				Add(b.seals[key], amount)
				DebugEvent(ts, subEvent, spell, dstName, amount, select(17, ...), SHORT[key])
			else
				DebugEvent(ts, subEvent, spell, dstName, amount, select(17, ...), "IGNORED: not a seal")
			end
		elseif subEvent == "SPELL_MISSED" and debugOn then
			DebugEvent(ts, subEvent, select(10, ...), dstName, select(12, ...), nil, "missed, not counted")
		end
	end
end)

-- ---------------------------------------------------------------------------
-- Comandos: /silvio
-- ---------------------------------------------------------------------------
local function Print(s)
	DEFAULT_CHAT_FRAME:AddMessage("|cff7fbfffSilvioSwinger|r: " .. s)
end

-- ---------------------------------------------------------------------------
-- Aviso de versão nova. O cliente 2.4.3 não acessa a internet, então quem tem o
-- addon troca a versão por mensagem de addon (guilda, grupo, raide, BG). Se alguém
-- tiver uma versão mais nova que a sua, avisa uma vez no chat com o link do Release.
-- ---------------------------------------------------------------------------
local RELEASES_URL = "https://github.com/SilvioDoMine/Silvio-Swinger-WoW-Addon/releases/latest"
local COMM_PREFIX = "SilvioSwinger"
local COMM_THROTTLE = 60  -- no máximo uma mensagem por canal a cada 60s
local newestSeen          -- maior versão já avisada nesta sessão
local lastSent = {}       -- canal -> GetTime() do último envio
local announceAt          -- primeiro anúncio alguns segundos depois do login

-- "1.2.3" ou "1.2.3-beta.1" -> major, minor, patch, pré-release (nil na versão final)
local function ParseVersion(v)
	local a, b, c, rest = string.match(v or "", "^(%d+)%.(%d+)%.(%d+)(.*)$")
	if not a then return end
	return tonumber(a), tonumber(b), tonumber(c), string.match(rest, "^%-([^+]+)")
end

-- true se a versão a for mais nova que b (SemVer; pré-releases comparadas como texto)
local function IsNewer(a, b)
	local a1, a2, a3, apre = ParseVersion(a)
	local b1, b2, b3, bpre = ParseVersion(b)
	if not a1 or not b1 then return false end
	if a1 ~= b1 then return a1 > b1 end
	if a2 ~= b2 then return a2 > b2 end
	if a3 ~= b3 then return a3 > b3 end
	if apre and bpre then return apre > bpre end
	return bpre ~= nil and apre == nil
end

local function SendVersion(channel)
	if not ParseVersion(VERSION) then return end
	local now = GetTime()
	if lastSent[channel] and now - lastSent[channel] < COMM_THROTTLE then return end
	lastSent[channel] = now
	SendAddonMessage(COMM_PREFIX, "V:" .. VERSION, channel)
end

local function AnnounceVersion()
	if IsInGuild() then SendVersion("GUILD") end
	local _, instanceType = IsInInstance()
	if instanceType == "pvp" then SendVersion("BATTLEGROUND")
	elseif GetNumRaidMembers() > 0 then SendVersion("RAID")
	elseif GetNumPartyMembers() > 0 then SendVersion("PARTY") end
end

local vc = CreateFrame("Frame")
vc:RegisterEvent("PLAYER_LOGIN")
vc:RegisterEvent("CHAT_MSG_ADDON")
vc:RegisterEvent("PARTY_MEMBERS_CHANGED")
vc:RegisterEvent("RAID_ROSTER_UPDATE")
vc:SetScript("OnEvent", function(self, event, prefix, msg, channel, sender)
	if event == "PLAYER_LOGIN" then
		-- a guilda ainda não está pronta no login
		announceAt = GetTime() + 10
	elseif not db then
		return  -- não é paladino: o addon está desligado
	elseif event == "CHAT_MSG_ADDON" then
		if prefix ~= COMM_PREFIX or sender == UnitName("player") then return end
		local v = string.match(msg or "", "^V:(.+)$")
		if not v then return end
		if IsNewer(v, VERSION) then
			if not newestSeen or IsNewer(v, newestSeen) then
				newestSeen = v
				Print(string.format(L.UPDATE_AVAILABLE, v, VERSION, RELEASES_URL))
			end
		elseif IsNewer(VERSION, v) then
			-- quem mandou está desatualizado: responde no mesmo canal para ele ficar sabendo
			SendVersion(channel)
		end
	elseif not announceAt then
		AnnounceVersion()  -- entrou num grupo ou raide
	end
end)
vc:SetScript("OnUpdate", function(self)
	if announceAt and GetTime() >= announceAt then
		announceAt = nil
		self:Hide()  -- frame escondido continua recebendo eventos, só para o OnUpdate
		if db then AnnounceVersion() end
	end
end)

-- ---------------------------------------------------------------------------
-- Painel em Interface Options (ESC > Interface > AddOns > SilvioSwinger)
-- ---------------------------------------------------------------------------
local optionsPanel

-- Esconder = invisível e sem mouse, mas a lógica (swing, dano no topo) continua rodando
function SetHidden(v)
	db.hidden = v
	f:SetAlpha(v and 0 or 1)
	f:EnableMouse(not v)
end

local function ResetPosition()
	db.point = { unpack(defaults.point) }
	f:ClearAllPoints() f:SetPoint(unpack(db.point))
end

function BuildOptions()
	local panel = CreateFrame("Frame", "SilvioSwingerOptions", UIParent)
	panel.name = "SilvioSwinger"
	panel:Hide()

	-- O painel do 2.4.3 é estreito e baixo: tudo fica numa coluna com barra de rolagem
	local scroll = CreateFrame("ScrollFrame", "SilvioSwingerOptionsScroll", panel, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", 0, -4)
	scroll:SetPoint("BOTTOMRIGHT", -26, 4)
	local content = CreateFrame("Frame", nil, scroll)
	content:SetWidth(360) content:SetHeight(700)
	scroll:SetScrollChild(content)

	local title = content:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", 16, -16)
	title:SetText("SilvioSwinger v" .. VERSION)
	local desc = content:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	desc:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
	desc:SetWidth(340) desc:SetJustifyH("LEFT")

	-- Textos do painel ficam numa lista para poderem ser trocados ao mudar o idioma
	local labels = {}
	local function Label(fs, key)
		table.insert(labels, { fs, key })
		return fs
	end
	Label(desc, "DESC")

	-- Idioma
	local langLabel = Label(content:CreateFontString(nil, "ARTWORK", "GameFontNormal"), "LANGUAGE")
	langLabel:SetPoint("TOPLEFT", desc, "BOTTOMLEFT", 0, -12)

	-- Largura e texto do dropdown direto nas partes do template:
	-- as funções UIDropDownMenu_SetWidth/SetText mudaram de assinatura entre versões
	local dd = CreateFrame("Frame", "SilvioSwingerOptLanguage", content, "UIDropDownMenuTemplate")
	dd:SetPoint("TOPLEFT", langLabel, "BOTTOMLEFT", -16, -2)
	getglobal("SilvioSwingerOptLanguageMiddle"):SetWidth(180)
	getglobal("SilvioSwingerOptLanguageText"):SetWidth(180)
	dd:SetWidth(180 + 50)

	local function LocaleLabel(code)
		if code == "auto" then
			return string.format(L.LANG_AUTO, LOCALES[ResolveLocale(GetLocale())]._name)
		end
		-- idioma salvo cujo arquivo foi removido: mostra o código mesmo
		return LOCALES[code] and LOCALES[code]._name or code
	end

	local function RefreshTexts()
		for _, e in ipairs(labels) do e[1]:SetText(L[e[2]]) end
		getglobal("SilvioSwingerOptLanguageText"):SetText(LocaleLabel(db.locale))
	end

	UIDropDownMenu_Initialize(dd, function()
		local function Add(code)
			local info = {}
			info.text = LocaleLabel(code)
			info.value = code
			info.checked = (db.locale == code) and 1 or nil
			info.func = function()
				db.locale = code
				ApplyLocale()
				RefreshTexts()
			end
			UIDropDownMenu_AddButton(info)
		end
		Add("auto")
		for _, code in ipairs(LocaleCodes()) do Add(code) end
	end)

	-- Checkbox ligado a um campo do db
	local function Check(key, label, anchor, onChange)
		local cb = CreateFrame("CheckButton", "SilvioSwingerOpt_" .. key, content, "OptionsCheckButtonTemplate")
		cb:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -2)
		Label(getglobal(cb:GetName() .. "Text"), label)
		cb:SetScript("OnShow", function(self) self:SetChecked(db[key] and 1 or nil) end)
		cb:SetScript("OnClick", function(self)
			db[key] = self:GetChecked() and true or false
			if onChange then onChange(db[key]) end
		end)
		return cb
	end

	-- Slider ligado a um campo do db (fmt formata o valor mostrado)
	local function Slider(key, label, low, high, step, fmt, anchor, onChange)
		local name = "SilvioSwingerOpt_" .. key
		local sl = CreateFrame("Slider", name, content, "OptionsSliderTemplate")
		sl:SetWidth(200)
		sl:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -26)
		sl:SetMinMaxValues(low, high)
		sl:SetValueStep(step)
		Label(getglobal(name .. "Text"), label)
		getglobal(name .. "Low"):SetText(string.format(fmt, low))
		getglobal(name .. "High"):SetText(string.format(fmt, high))
		local val = sl:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
		val:SetPoint("LEFT", sl, "RIGHT", 8, 0)
		sl:SetScript("OnShow", function(self)
			self.loading = true
			self:SetValue(db[key])
			self.loading = nil
			val:SetText(string.format(fmt, db[key]))
		end)
		sl:SetScript("OnValueChanged", function(self, v)
			v = math.floor(v / step + 0.5) * step
			val:SetText(string.format(fmt, v))
			if self.loading then return end
			db[key] = v
			if onChange then onChange(v) end
		end)
		return sl
	end

	-- Opções liga/desliga
	local anchor = CreateFrame("Frame", nil, content)
	anchor:SetWidth(1) anchor:SetHeight(1)
	anchor:SetPoint("TOPLEFT", dd, "BOTTOMLEFT", 14, -6)

	local c1 = Check("hidden", "OPT_HIDDEN", anchor, SetHidden)
	local c2 = Check("locked", "OPT_LOCKED", c1)
	local c3 = Check("judge", "OPT_JUDGE", c2)
	local c4 = Check("sound", "OPT_SOUND", c3, function(v)
		if v then PlayTwistSound() end
	end)
	local c5 = Check("dmgMsg", "OPT_DMGMSG", c4)
	local c6 = Check("breakdown", "OPT_BREAKDOWN", c5)

	-- Sliders de tempo / aparência, embaixo das opções
	local header = Label(content:CreateFontString(nil, "ARTWORK", "GameFontNormal"), "HEADER_TUNING")
	header:SetPoint("TOPLEFT", c6, "BOTTOMLEFT", 4, -16)

	local s1 = Slider("window", "SL_WINDOW", 0.10, 0.80, 0.01, "%.2fs", header)
	local s2 = Slider("buffer", "SL_BUFFER", 0, 0.30, 0.01, "%.2fs", s1)
	local s3 = Slider("csSlack", "SL_CSSLACK", 0, 0.50, 0.01, "%.2fs", s2)
	local s4 = Slider("lowMana", "SL_LOWMANA", 0, 0.50, 0.01, "%.2f", s3)
	local s5 = Slider("scale", "SL_SCALE", 0.5, 2.0, 0.05, "%.2f", s4, function(v) f:SetScale(v) end)

	-- Botões
	local b1 = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
	b1:SetWidth(150) b1:SetHeight(22)
	b1:SetPoint("TOPLEFT", s5, "BOTTOMLEFT", 0, -30)
	Label(b1, "BTN_RESET_POS")
	b1:SetScript("OnClick", ResetPosition)

	local b2 = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
	b2:SetWidth(150) b2:SetHeight(22)
	b2:SetPoint("LEFT", b1, "RIGHT", 8, 0)
	Label(b2, "BTN_RESET_STATS")
	b2:SetScript("OnClick", function()
		twistStats.count, twistStats.total, twistStats.biggest = 0, 0, 0
		streak, best = 0, 0
	end)

	local stats = content:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	stats:SetPoint("TOPLEFT", b1, "BOTTOMLEFT", 0, -12)
	stats:SetWidth(340) stats:SetJustifyH("LEFT")
	panel:SetScript("OnUpdate", function()
		local c = twistStats.count
		stats:SetText(string.format(L.STATS,
			c, twistStats.total, c > 0 and twistStats.total / c or 0, twistStats.biggest, streak, best))
	end)

	local foot = content:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	foot:SetPoint("TOPLEFT", stats, "BOTTOMLEFT", 0, -16)
	foot:SetWidth(340) foot:SetJustifyH("LEFT")
	Label(foot, "FOOTER")

	RefreshTexts()
	panel:SetScript("OnShow", RefreshTexts)
	InterfaceOptions_AddCategory(panel)
	optionsPanel = panel
end

SLASH_SILVIOSWINGER1 = "/silvio"
SLASH_SILVIOSWINGER2 = "/ss"
SlashCmdList.SILVIOSWINGER = function(input)
	local cmd, arg = string.match(input or "", "^(%S*)%s*(.-)$")
	cmd = string.lower(cmd or "")
	local n = tonumber(arg)
	if not db then return end
	if cmd == "config" or cmd == "opcoes" then
		InterfaceOptionsFrame_OpenToFrame(optionsPanel)
	elseif cmd == "lock" then db.locked = true Print(L.CHAT_LOCKED)
	elseif cmd == "unlock" then db.locked = false Print(L.CHAT_UNLOCKED)
	elseif cmd == "window" and n then db.window = n Print(string.format(L.CHAT_WINDOW, n))
	elseif cmd == "buffer" and n then db.buffer = n Print(string.format(L.CHAT_BUFFER, n))
	elseif cmd == "cs" and n then db.csSlack = n Print(string.format(L.CHAT_CS, n))
	elseif cmd == "scale" and n then db.scale = n f:SetScale(n) Print(string.format(L.CHAT_SCALE, n))
	elseif cmd == "judge" then db.judge = not db.judge Print(string.format(L.CHAT_JUDGE, OnOff(db.judge)))
	elseif cmd == "sound" then
		db.sound = not db.sound
		if db.sound then PlayTwistSound() end
		Print(string.format(L.CHAT_SOUND, OnOff(db.sound)))
	elseif cmd == "msg" then db.dmgMsg = not db.dmgMsg Print(string.format(L.CHAT_MSG, OnOff(db.dmgMsg)))
	elseif cmd == "detail" then db.breakdown = not db.breakdown Print(string.format(L.CHAT_DETAIL, OnOff(db.breakdown)))
	elseif cmd == "dmg" then
		local c = twistStats.count
		Print(string.format(L.CHAT_DMG,
			c, twistStats.total, c > 0 and twistStats.total / c or 0, twistStats.biggest))
	elseif cmd == "debug" then
		debugOn = not debugOn
		Print(string.format(L.CHAT_DEBUG, OnOff(debugOn)))
	elseif cmd == "dmgreset" then
		twistStats.count, twistStats.total, twistStats.biggest = 0, 0, 0
		Print(L.CHAT_DMGRESET)
	elseif cmd == "show" then SetHidden(false)
	elseif cmd == "hide" then SetHidden(true)
	elseif cmd == "lang" or cmd == "idioma" then
		-- aceita "auto" ou um código de Locales/ sem diferenciar maiúsculas (ptbr, PTBR...)
		local want = string.lower(arg or "")
		local found = want == "auto" and "auto" or nil
		for _, code in ipairs(LocaleCodes()) do
			if string.lower(code) == want then found = code end
		end
		if found then
			db.locale = found
			ApplyLocale()
			Print(string.format(L.CHAT_LANG, LOCALES[L._code]._name))
		else
			Print(string.format(L.CHAT_LANG_UNKNOWN, arg or "", "auto, " .. table.concat(LocaleCodes(), ", ")))
		end
	elseif cmd == "reset" then
		streak, best = 0, 0
		ResetPosition()
		Print(L.CHAT_RESET)
	else
		Print("v" .. VERSION)
		Print(string.format(L.CHAT_STATUS,
			twistKey and S[twistKey].name or L.NONE, speed, db.window, db.buffer))
		Print("/silvio config | lock | unlock | window <s> | buffer <s> | cs <s> | scale <n> | judge | sound | msg | detail | dmg | dmgreset | show | hide | lang <auto|enUS|ptBR|...> | debug | reset")
	end
end
