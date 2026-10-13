-- SilvioSwinger: indicador simples de seal twisting para Paladino (cliente 2.4.3)
-- Ideia: SoC ativo -> nos últimos ~0.4s antes do swing, troca para SoB/SoR/Martyr.
-- O swing que cai logo depois proca os dois selos. Depois: Julgamento (fora do GCD) + SoC de novo.

local ADDON = "SilvioSwinger"

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
	point    = { "CENTER", "UIParent", "CENTER", 0, -160 },
}

local db
local playerGUID
local BuildOptions, SetHidden  -- definidas lá embaixo, junto do painel de opções

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
local hit                  -- pacote atual: { start, white, seals = {key=dano}, twist }
local twistStats = { count = 0, total = 0, biggest = 0 }

local function SealKeyByName(name)
	for _, k in ipairs(SEAL_ORDER) do
		if S[k] and S[k].name == name then return k end
	end
end

local function HitBucket()
	if not hit then hit = { start = GetTime(), white = 0, seals = {} } end
	return hit
end

local function FlushHit(force)
	if not hit then return end
	if not force and GetTime() - hit.start < 0.4 then return end
	local b = hit
	hit = nil

	local nSeals, sealDmg = 0, 0
	for _, dmg in pairs(b.seals) do
		nSeals = nSeals + 1
		sealDmg = sealDmg + dmg
	end
	-- twist = dois selos procaram juntos, ou o twist foi feito no tempo certo
	if nSeals < 2 and not b.twist then return end

	local total = b.white + sealDmg
	if total <= 0 then return end
	twistStats.count = twistStats.count + 1
	twistStats.total = twistStats.total + total
	if total > twistStats.biggest then twistStats.biggest = total end

	if db.dmgMsg then
		local text = "TWIST DAMAGE: " .. total
		if db.breakdown then
			local parts = { "hit " .. b.white }
			for _, k in ipairs(SEAL_ORDER) do
				if b.seals[k] then table.insert(parts, SHORT[k] .. " " .. b.seals[k]) end
			end
			text = text .. "  (" .. table.concat(parts, " + ") .. ")"
		end
		UIErrorsFrame:AddMessage(text, 0.25, 0.6, 1.0, 1.0, UIERRORS_HOLD_TIME)
	end
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
			lastResult = "PERFEITO"
			HitBucket().twist = true
		else
			streak = 0
			lastResult = "CEDO DEMAIS"
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

	-- retorna: ícone agora, ícone próximo, mensagem, cor {r,g,b}, brilho
	if not Knows("COMMAND") then
		return nil, false, "Sem Seal of Command", { 1, 0.3, 0.3 }, false
	end

	-- Fora de combate / sem swing conhecido: só prepare o SoC
	if not t then
		if seal == "COMMAND" then
			return "COMMAND", tw or false, "Pronto (SoC)", { 0.6, 1, 0.6 }, false
		end
		return "COMMAND", tw or false, "Prepare SoC", { 1, 0.82, 0 }, gcd == 0
	end

	if seal == "COMMAND" then
		if not tw then
			return "COMMAND", false, "Sem selo p/ twist", { 1, 0.5, 0 }, false
		end
		if t <= db.window and t > lat then
			if gcd <= t - lat then
				return tw, "JUDGE", "TWIST!", { 0.2, 1, 0.2 }, true
			end
			return tw, "COMMAND", "GCD: perdeu", { 1, 0.3, 0.3 }, false
		elseif t <= lat then
			return tw, "COMMAND", "Tarde demais", { 1, 0.3, 0.3 }, false
		end
		-- Ainda longe da janela: dá pra encaixar Crusader Strike?
		local toWindow = t - db.window
		if csCD and csCD <= gcd and toWindow >= gcd + gcdDuration + db.csSlack then
			return "CS", tw, "Crusader Strike", { 1, 0.82, 0 }, gcd == 0
		end
		return tw, "JUDGE", string.format("Espere %.1fs", toWindow), { 0.8, 0.8, 0.8 }, false
	end

	-- Selo de twist ativo (pós-swing) ou nenhum selo
	if seal == tw and db.judge and jCD and jCD == 0 then
		return "JUDGE", "COMMAND", "Julgamento + SoC", { 1, 0.82, 0 }, true
	end
	if gcd > 0 then
		return "COMMAND", false, string.format("SoC em %.1fs", gcd), { 0.8, 0.8, 0.8 }, false
	end
	return "COMMAND", tw or false, "Seal of Command", { 1, 0.82, 0 }, true
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
		barText:SetText(attacking and "swing pronto" or string.format("%.2f", speed))
	end
end

local acc = 0
f:SetScript("OnUpdate", function(self, elapsed)
	acc = acc + elapsed
	if acc < 0.02 then return end
	acc = 0

	FlushHit()

	local nowKey, nextKey, text, color, shine = Recommend()
	SetIcon(nowIcon, nowKey)
	SetIcon(nextIcon, nextKey)
	msg:SetText(text)
	msg:SetTextColor(color[1], color[2], color[3])
	if shine then glow:Show() else glow:Hide() end

	if text == "TWIST!" and db.sound and soundPlayedFor ~= nextSwing then
		soundPlayedFor = nextSwing
		PlaySound("igMainMenuOptionCheckBoxOn")
	end

	local mana, maxMana = UnitMana("player"), UnitManaMax("player")
	local lat = Latency()
	local info = string.format("lat %dms", lat * 1000)
	if maxMana > 0 and mana / maxMana < db.lowMana then
		info = "|cffff4040MANA BAIXA|r  " .. info
	end
	sub:SetText(info)

	if twistStats.count > 0 then
		streakText:SetText(string.format("Streak %d (melhor %d)  média %d",
			streak, best, twistStats.total / twistStats.count))
	else
		streakText:SetText(string.format("Streak %d (melhor %d)", streak, best))
	end
	if lastResult and GetTime() - lastResultAt < 1.5 then
		resultText:SetText(lastResult)
		if lastResult == "PERFEITO" then resultText:SetTextColor(0.2, 1, 0.2)
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
				lastResult, lastResultAt = "ATRASADO", now
				twistCastAt = nil
			else
				twistCastAt = now
			end
		end

	elseif event == "COMBAT_LOG_EVENT_UNFILTERED" then
		local _, subEvent, srcGUID, _, _, dstGUID = ...
		if srcGUID ~= playerGUID then return end
		if subEvent == "SWING_DAMAGE" then
			local b = HitBucket()
			b.white = b.white + (select(9, ...) or 0)
			OnSwing()
		elseif subEvent == "SWING_MISSED" then
			OnSwing()
		elseif subEvent == "SPELL_DAMAGE" and dstGUID ~= playerGUID then
			-- dstGUID ~= player: ignora o dano que o Seal of Blood causa em você
			local key = SealKeyByName((select(10, ...)))
			if key then
				local b = HitBucket()
				b.seals[key] = (b.seals[key] or 0) + (select(12, ...) or 0)
			end
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

	local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", 16, -16)
	title:SetText("SilvioSwinger")
	local desc = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	desc:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
	desc:SetText("Seal twisting para Paladino Retribution. Shift + arrastar move a janela.")

	-- Checkbox ligado a um campo do db
	local function Check(key, label, anchor, onChange)
		local cb = CreateFrame("CheckButton", "SilvioSwingerOpt_" .. key, panel, "OptionsCheckButtonTemplate")
		cb:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -2)
		getglobal(cb:GetName() .. "Text"):SetText(label)
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
		local sl = CreateFrame("Slider", name, panel, "OptionsSliderTemplate")
		sl:SetWidth(200)
		sl:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -26)
		sl:SetMinMaxValues(low, high)
		sl:SetValueStep(step)
		getglobal(name .. "Text"):SetText(label)
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

	-- Coluna esquerda: opções liga/desliga
	local anchor = CreateFrame("Frame", nil, panel)
	anchor:SetWidth(1) anchor:SetHeight(1)
	anchor:SetPoint("TOPLEFT", desc, "BOTTOMLEFT", -2, -8)

	local c1 = Check("hidden", "Esconder a janela", anchor, SetHidden)
	local c2 = Check("locked", "Travar posição (nem com Shift move)", c1)
	local c3 = Check("judge", "Sugerir Julgamento depois do twist", c2)
	local c4 = Check("sound", "Som quando a janela de twist abre", c3)
	local c5 = Check("dmgMsg", "Mostrar \"TWIST DAMAGE\" no topo da tela", c4)
	local c6 = Check("breakdown", "Detalhar o dano (hit + SoC + SoB)", c5)

	-- Coluna direita: sliders de tempo / aparência
	local right = CreateFrame("Frame", nil, panel)
	right:SetWidth(1) right:SetHeight(1)
	right:SetPoint("TOPLEFT", panel, "TOPLEFT", 330, -50)

	local s1 = Slider("window", "Janela de twist", 0.10, 0.80, 0.01, "%.2fs", right)
	local s2 = Slider("buffer", "Margem extra (além da latência)", 0, 0.30, 0.01, "%.2fs", s1)
	local s3 = Slider("csSlack", "Folga para Crusader Strike", 0, 0.50, 0.01, "%.2fs", s2)
	local s4 = Slider("lowMana", "Aviso de mana baixa", 0, 0.50, 0.01, "%.2f", s3)
	local s5 = Slider("scale", "Escala da janela", 0.5, 2.0, 0.05, "%.2f", s4, function(v) f:SetScale(v) end)

	-- Botões
	local b1 = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
	b1:SetWidth(150) b1:SetHeight(22)
	b1:SetPoint("TOPLEFT", c6, "BOTTOMLEFT", 4, -20)
	b1:SetText("Resetar posição")
	b1:SetScript("OnClick", ResetPosition)

	local b2 = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
	b2:SetWidth(150) b2:SetHeight(22)
	b2:SetPoint("LEFT", b1, "RIGHT", 8, 0)
	b2:SetText("Zerar dano / streak")
	b2:SetScript("OnClick", function()
		twistStats.count, twistStats.total, twistStats.biggest = 0, 0, 0
		streak, best = 0, 0
	end)

	local stats = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	stats:SetPoint("TOPLEFT", b1, "BOTTOMLEFT", 0, -12)
	stats:SetJustifyH("LEFT")
	panel:SetScript("OnUpdate", function()
		local c = twistStats.count
		stats:SetText(string.format("Twists: %d   Dano total: %d   Média: %d   Maior: %d   Streak: %d (melhor %d)",
			c, twistStats.total, c > 0 and twistStats.total / c or 0, twistStats.biggest, streak, best))
	end)

	local foot = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	foot:SetPoint("BOTTOMLEFT", 16, 16)
	foot:SetText("Comandos: /silvio ou /ss  (/silvio config abre este painel)")

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
	elseif cmd == "lock" then db.locked = true Print("travado")
	elseif cmd == "unlock" then db.locked = false Print("destravado (arraste a janela)")
	elseif cmd == "window" and n then db.window = n Print("janela = " .. n .. "s")
	elseif cmd == "buffer" and n then db.buffer = n Print("buffer = " .. n .. "s")
	elseif cmd == "cs" and n then db.csSlack = n Print("folga CS = " .. n .. "s")
	elseif cmd == "scale" and n then db.scale = n f:SetScale(n) Print("escala = " .. n)
	elseif cmd == "judge" then db.judge = not db.judge Print("julgamento: " .. tostring(db.judge))
	elseif cmd == "sound" then db.sound = not db.sound Print("som: " .. tostring(db.sound))
	elseif cmd == "msg" then db.dmgMsg = not db.dmgMsg Print("mensagem de dano: " .. tostring(db.dmgMsg))
	elseif cmd == "detail" then db.breakdown = not db.breakdown Print("detalhes do dano: " .. tostring(db.breakdown))
	elseif cmd == "dmg" then
		local c = twistStats.count
		Print(string.format("twists: %d | dano total: %d | média: %d | maior: %d",
			c, twistStats.total, c > 0 and twistStats.total / c or 0, twistStats.biggest))
	elseif cmd == "dmgreset" then
		twistStats.count, twistStats.total, twistStats.biggest = 0, 0, 0
		Print("contagem de dano zerada")
	elseif cmd == "show" then SetHidden(false)
	elseif cmd == "hide" then SetHidden(true)
	elseif cmd == "reset" then
		streak, best = 0, 0
		ResetPosition()
		Print("resetado")
	else
		Print(string.format("selo de twist: %s | arma %.2fs | janela %.2fs | buffer %.2fs",
			twistKey and S[twistKey].name or "nenhum", speed, db.window, db.buffer))
		Print("/silvio config | lock | unlock | window <s> | buffer <s> | cs <s> | scale <n> | judge | sound | msg | detail | dmg | dmgreset | show | hide | reset")
	end
end
