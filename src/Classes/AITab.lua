-- AI Build Advisor Tab
-- Supports Anthropic API and local OpenAI-compatible servers (Ollama, LM Studio)

local t_insert = table.insert
local t_remove = table.remove
local m_floor = math.floor
local dkjson = require "dkjson"

-- Providers
local PROVIDER_ANTHROPIC = 1
local PROVIDER_LOCAL     = 2
local PROVIDERS = { "Anthropic API", "Local (Ollama / LM Studio)" }

-- Anthropic model list
local ANTH_MODELS = {
	{ label = "Haiku  (Fast)",     id = "claude-3-5-haiku-20241022"  },
	{ label = "Sonnet (Balanced)", id = "claude-3-5-sonnet-20241022" },
	{ label = "Opus   (Smart)",    id = "claude-3-opus-20240229"     },
}
local DEFAULT_ANTH_MODEL = 2  -- Sonnet

-- Fallback class name→ID map
local CLASS_NAME_MAP = {
	scion = 0, marauder = 1, ranger = 2,
	witch = 3, duelist = 4, templar = 5, shadow = 6,
}

-- System prompt shared by both requests
local SYSTEM_PROMPT = [[You are an expert Path of Exile build advisor embedded inside Path of Building. When given a build request, provide:
1. Build concept summary (2-3 sentences)
2. Recommended class and ascendancy
3. Core skill gems (main 6-link with support gems)
4. Key passive tree priorities (clusters and notable nodes to aim for)
5. Essential unique items
6. Stat priorities for rare items
Be specific, practical, and concise. If a current build context is provided, tailor advice to improve or pivot it.]]

local AITabClass = newClass("AITab", "ControlHost", "Control", function(self, build)
	self.ControlHost()
	self.Control()
	self.build = build

	-- State
	self.aiStatus   = ""
	self.aiResponse = ""
	self.apiKey     = main.aiAPIKey or ""
	self.provider   = main.aiProvider or PROVIDER_ANTHROPIC
	self.localUrl   = main.aiLocalUrl or "http://localhost:11434/v1/chat/completions"
	self.localModel = main.aiLocalModel or "llama3"
	self.requesting = false
	self.includeContext = true
	self.anthModelIndex = DEFAULT_ANTH_MODEL

	-- ================================================================
	--  Provider selector
	-- ================================================================
	self.controls.providerLabel = new("LabelControl", {"TOPLEFT",self,"TOPLEFT"}, {20, 20, 0, 16},
		"^7Provider:")
	self.controls.providerDrop = new("DropDownControl", {"LEFT",self.controls.providerLabel,"RIGHT"}, {8, 0, 230, 20},
		PROVIDERS, function(index)
			self.provider = index
			main.aiProvider = index
			main:SaveSettings()
		end)
	self.controls.providerDrop.selIndex = self.provider

	-- ================================================================
	--  Anthropic API Key (grayed when Local)
	-- ================================================================
	self.controls.apiKeyLabel = new("LabelControl", {"TOPLEFT",self.controls.providerLabel,"BOTTOMLEFT"}, {0, 12, 0, 16},
		"^7Anthropic API Key:")
	self.controls.apiKeyInput = new("EditControl", {"TOPLEFT",self.controls.apiKeyLabel,"BOTTOMLEFT"}, {0, 4, 380, 20},
		self.apiKey, nil, nil, nil, function(buf)
			self.apiKey = buf
			main.aiAPIKey = buf
			main:SaveSettings()
		end)
	self.controls.apiKeyInput:SetProtected(true)
	self.controls.apiKeyInput.enabled = function() return self.provider == PROVIDER_ANTHROPIC end

	self.controls.apiKeySaveNote = new("LabelControl", {"LEFT",self.controls.apiKeyInput,"RIGHT"}, {8, 0, 0, 16},
		"^8Saved to settings")

	-- ================================================================
	--  Local URL + model name (grayed when Anthropic)
	-- ================================================================
	self.controls.localUrlLabel = new("LabelControl", {"TOPLEFT",self.controls.apiKeyInput,"BOTTOMLEFT"}, {0, 8, 0, 16},
		"^7Local URL:")
	self.controls.localUrlInput = new("EditControl", {"TOPLEFT",self.controls.localUrlLabel,"BOTTOMLEFT"}, {0, 4, 360, 20},
		self.localUrl, "http://localhost:11434/v1/chat/completions", nil, 300, function(buf)
			self.localUrl = buf
			main.aiLocalUrl = buf
			main:SaveSettings()
		end)
	self.controls.localUrlInput.enabled = function() return self.provider == PROVIDER_LOCAL end

	self.controls.localModelLabel = new("LabelControl", {"LEFT",self.controls.localUrlInput,"RIGHT"}, {12, 0, 0, 16},
		"^7Model:")
	self.controls.localModelInput = new("EditControl", {"LEFT",self.controls.localModelLabel,"RIGHT"}, {4, 0, 120, 20},
		self.localModel, "llama3", nil, 100, function(buf)
			self.localModel = buf
			main.aiLocalModel = buf
			main:SaveSettings()
		end)
	self.controls.localModelInput.enabled = function() return self.provider == PROVIDER_LOCAL end

	-- ================================================================
	--  Anthropic model dropdown (grayed when Local)
	-- ================================================================
	self.controls.anthModelLabel = new("LabelControl", {"TOPLEFT",self.controls.localUrlInput,"BOTTOMLEFT"}, {0, 8, 0, 16},
		"^7Model:")
	local modelList = {}
	for _, m in ipairs(ANTH_MODELS) do t_insert(modelList, m.label) end
	self.controls.anthModelDrop = new("DropDownControl", {"LEFT",self.controls.anthModelLabel,"RIGHT"}, {8, 0, 200, 20},
		modelList, function(index) self.anthModelIndex = index end)
	self.controls.anthModelDrop.selIndex = DEFAULT_ANTH_MODEL
	self.controls.anthModelDrop.enabled = function() return self.provider == PROVIDER_ANTHROPIC end

	-- ================================================================
	--  Prompt
	-- ================================================================
	self.controls.promptLabel = new("LabelControl", {"TOPLEFT",self.controls.anthModelLabel,"BOTTOMLEFT"}, {0, 12, 0, 16},
		"^7Describe the build you want:")
	self.controls.promptInput = new("EditControl", {"TOPLEFT",self.controls.promptLabel,"BOTTOMLEFT"}, {0, 4, 0, 20},
		"", "e.g. tanky lightning strike slayer, or fire dot elementalist", nil, 500)
	self.controls.promptInput.width = function() return self.width - 40 end

	-- ================================================================
	--  Generate button + context checkbox
	-- ================================================================
	self.controls.generateBtn = new("ButtonControl", {"TOPLEFT",self.controls.promptInput,"BOTTOMLEFT"}, {0, 10, 140, 22},
		"Generate Build", function() self:SendRequest() end)
	self.controls.generateBtn.enabled = function()
		if self.requesting or #self.controls.promptInput.buf == 0 then return false end
		if self.provider == PROVIDER_ANTHROPIC then return #self.apiKey > 0 end
		return true  -- local: no key needed
	end

	self.controls.includeContextChk = new("CheckBoxControl", {"TOPLEFT",self.controls.generateBtn,"BOTTOMLEFT"}, {220, 8, 18, 18},
		"Include current build as context", function(state) self.includeContext = state end, nil, true)

	-- ================================================================
	--  Status + response
	-- ================================================================
	self.controls.statusLabel = new("LabelControl", {"TOPLEFT",self.controls.includeContextChk,"BOTTOMLEFT"}, {-220, 6, 0, 16},
		function() return self.aiStatus end)

	self.controls.responseLabel = new("LabelControl", {"TOPLEFT",self.controls.statusLabel,"BOTTOMLEFT"}, {0, 4, 0, 16},
		"^7Response:")
	self.controls.responseBox = new("EditControl", {"TOPLEFT",self.controls.responseLabel,"BOTTOMLEFT"}, {0, 4, 0, 0},
		"", nil, nil, nil, nil, 16)
	self.controls.responseBox.width  = function() return self.width - 40 end
	self.controls.responseBox.height = function() return self.height - 420 end

	-- ================================================================
	--  Buttons
	-- ================================================================
	self.controls.copyBtn = new("ButtonControl", {"TOPLEFT",self.controls.responseBox,"BOTTOMLEFT"}, {0, 6, 100, 20},
		"Copy Response", function() Copy(self.aiResponse) end)
	self.controls.copyBtn.enabled = function() return #self.aiResponse > 0 end

	self.controls.clearBtn = new("ButtonControl", {"LEFT",self.controls.copyBtn,"RIGHT"}, {8, 0, 80, 20},
		"Clear", function()
			self.aiResponse = ""
			self.aiStatus = ""
			self.controls.responseBox:SetText("")
		end)

	self.controls.applyBtn = new("ButtonControl", {"LEFT",self.controls.clearBtn,"RIGHT"}, {8, 0, 160, 20},
		"Apply Build to PoB", function() self:ApplyBuild() end)
	self.controls.applyBtn.enabled = function()
		return not self.requesting and #self.aiResponse > 0
	end
end)

-- ================================================================
--  Draw
-- ================================================================
function AITabClass:Draw(viewPort, inputEvents)
	self.x = viewPort.x
	self.y = viewPort.y
	self.width = viewPort.width
	self.height = viewPort.height

	-- Sync persisted settings loaded after construction
	if main.aiAPIKey ~= "" and self.apiKey ~= main.aiAPIKey then
		self.apiKey = main.aiAPIKey
		self.controls.apiKeyInput:SetText(main.aiAPIKey)
	end

	self:ProcessControlsInput(inputEvents, viewPort)
	main:DrawBackground(viewPort)
	self:DrawControls(viewPort)
end

-- ================================================================
--  Build context helper
-- ================================================================
function AITabClass:BuildContext()
	local build = self.build
	local lines = {}

	local className  = build.spec.curClassName or "Unknown"
	local ascendName = build.spec.curAscendClassName or "None"
	t_insert(lines, "Class: " .. className .. " / Ascendancy: " .. ascendName)
	t_insert(lines, "Level: " .. (build.characterLevel or 1))

	local mainGroup = build.skillsTab.socketGroupList[build.mainSocketGroup]
	if mainGroup then
		local skillNames = {}
		for _, gem in ipairs(mainGroup.gemList) do
			if gem.nameSpec then t_insert(skillNames, gem.nameSpec) end
		end
		t_insert(lines, "Main skill: " .. table.concat(skillNames, " + "))
	end

	local output = build.calcsTab.mainOutput
	if output then
		local life = output.Life or 0
		local es   = output.EnergyShield or 0
		if output.ChaosInoculation then
			t_insert(lines, "Defence: Chaos Inoculation (ES)")
		elseif es > life then
			t_insert(lines, "Defence: Energy Shield (" .. m_floor(es) .. " ES, " .. m_floor(life) .. " Life)")
		else
			t_insert(lines, "Defence: Life (" .. m_floor(life) .. " Life, " .. m_floor(es) .. " ES)")
		end
		if output.TotalDPS and output.TotalDPS > 0 then
			t_insert(lines, "Total DPS: " .. m_floor(output.TotalDPS))
		end
		local res = {}
		if output.FireResist      then t_insert(res, "Fire "      .. output.FireResist      .. "%") end
		if output.ColdResist      then t_insert(res, "Cold "      .. output.ColdResist      .. "%") end
		if output.LightningResist then t_insert(res, "Lightning " .. output.LightningResist .. "%") end
		if #res > 0 then t_insert(lines, "Resistances: " .. table.concat(res, ", ")) end
	end

	local keystones = {}
	for _, node in pairs(build.spec.allocNodes) do
		if node.isKeystone then t_insert(keystones, node.name) end
	end
	if #keystones > 0 then t_insert(lines, "Keystones: " .. table.concat(keystones, ", ")) end

	local weaponSlot = build.itemsTab.items["Weapon 1"]
	if weaponSlot and weaponSlot.type then t_insert(lines, "Main hand: " .. weaponSlot.type) end

	local nodeCount = 0
	for _ in pairs(build.spec.allocNodes) do nodeCount = nodeCount + 1 end
	t_insert(lines, "Passive points used: " .. nodeCount)

	return table.concat(lines, "\n")
end

-- ================================================================
--  Request helpers
-- ================================================================

-- Returns url, header, body for a chat request
function AITabClass:BuildRequestParams(systemMsg, userMsg, maxTokens)
	if self.provider == PROVIDER_ANTHROPIC then
		local model = ANTH_MODELS[self.anthModelIndex] and ANTH_MODELS[self.anthModelIndex].id
			or ANTH_MODELS[DEFAULT_ANTH_MODEL].id
		local body = string.format(
			'{"model":%s,"max_tokens":%d,"system":%s,"messages":[{"role":"user","content":%s}]}',
			jsonEncode(model), maxTokens, jsonEncode(systemMsg), jsonEncode(userMsg))
		local header = "Content-Type: application/json\nx-api-key: " .. self.apiKey .. "\nanthropic-version: 2023-06-01"
		return "https://api.anthropic.com/v1/messages", header, body
	else
		-- OpenAI-compatible (Ollama, LM Studio, llama.cpp server, etc.)
		local body = string.format(
			'{"model":%s,"max_tokens":%d,"messages":[{"role":"system","content":%s},{"role":"user","content":%s}],"stream":false}',
			jsonEncode(self.localModel), maxTokens, jsonEncode(systemMsg), jsonEncode(userMsg))
		return self.localUrl, "Content-Type: application/json", body
	end
end

-- Extracts text from either Anthropic or OpenAI-style response
function AITabClass:ParseResponseText(responseText)
	local data, _, err = dkjson.decode(responseText)
	if not data then
		return nil, "JSON parse failed"
	end
	-- Anthropic format
	if data.content and data.content[1] and data.content[1].text then
		return data.content[1].text
	end
	-- OpenAI-compatible format
	if data.choices and data.choices[1] and data.choices[1].message and data.choices[1].message.content then
		return data.choices[1].message.content
	end
	-- Error from either provider
	if data.error then
		local msg = type(data.error) == "string" and data.error
			or (data.error.message) or "unknown API error"
		return nil, msg
	end
	return nil, "Unexpected response format"
end

-- ================================================================
--  Generate Build
-- ================================================================
function AITabClass:SendRequest()
	if self.requesting then return end

	local prompt = self.controls.promptInput.buf
	if #prompt == 0 then self.aiStatus = "^1Error: No prompt entered" return end
	if self.provider == PROVIDER_ANTHROPIC and #self.apiKey == 0 then
		self.aiStatus = "^1Error: No API key set" return
	end

	self.requesting = true
	self.aiStatus   = "^xFFD700Sending request..."
	self.aiResponse = ""
	self.controls.responseBox:SetText("")

	local userMsg = prompt
	if self.includeContext then
		userMsg = "Current build context:\n" .. self:BuildContext() .. "\n\nRequest: " .. prompt
	end

	local url, header, body = self:BuildRequestParams(SYSTEM_PROMPT, userMsg, 1500)
	ConPrintf("AI: provider=%d url=%s body(200)=%s", self.provider, url, body:sub(1,200))

	launch:DownloadPage(url,
		function(response, errMsg)
			self.requesting = false
			if errMsg then
				local detail = ""
				if response and response.body and #response.body > 0 then
					ConPrintf("AI error body: %s", response.body:sub(1, 400))
					local edata = dkjson.decode(response.body)
					if edata and edata.error then
						detail = ": " .. (type(edata.error)=="string" and edata.error or edata.error.message or "")
					end
				end
				self.aiStatus = "^1Request failed: " .. errMsg .. detail
				return
			end
			local text, err2 = self:ParseResponseText(response.body)
			if text then
				self.aiResponse = text
				self.controls.responseBox:SetText(text)
				self.aiStatus = "^2Done! Use 'Apply Build to PoB' to apply."
			else
				self.aiStatus = "^1Error: " .. (err2 or "?")
				ConPrintf("AI raw response: %s", response.body:sub(1, 300))
			end
		end,
		{ header = header, body = body }
	)
end

-- ================================================================
--  Apply Build
-- ================================================================
function AITabClass:ApplyBuild()
	if self.requesting then return end
	if #self.aiResponse == 0 then self.aiStatus = "^1No response to apply" return end

	self.requesting = true
	self.aiStatus   = "^xFFD700Extracting build data..."

	local extractSys  = "You extract structured data from Path of Exile build descriptions. Output ONLY valid JSON with no surrounding text."
	local extractUser = table.concat({
		"From the following Path of Exile build advice, extract a JSON object with exactly these fields:",
		"  \"class\": one of [Marauder, Ranger, Witch, Duelist, Templar, Shadow, Scion]",
		"  \"ascendancy\": the ascendancy subclass name, or \"None\" if not mentioned",
		"  \"gems\": an array of up to 6 gem name strings for the main skill link (active skill first, then supports)",
		"",
		"Rules:",
		"- Output ONLY valid JSON. No markdown, no explanation, no code fences.",
		"- Use exact PoB gem names where possible (e.g. \"Lightning Strike\", \"Multistrike Support\").",
		"- If the class is not clearly stated, infer it from the ascendancy.",
		"- If a field cannot be determined, use null for strings or [] for gems.",
		"",
		"Build advice:",
		self.aiResponse,
	}, "\n")

	local url, header, body = self:BuildRequestParams(extractSys, extractUser, 400)

	launch:DownloadPage(url,
		function(response, errMsg)
			self.requesting = false
			if errMsg then
				local detail = ""
				if response and response.body and #response.body > 0 then
					local edata = dkjson.decode(response.body)
					if edata and edata.error then
						detail = ": " .. (type(edata.error)=="string" and edata.error or edata.error.message or "")
					end
				end
				self.aiStatus = "^1Apply failed: " .. errMsg .. detail
				return
			end
			local text, err2 = self:ParseResponseText(response.body)
			if not text then
				self.aiStatus = "^1Apply error: " .. (err2 or "?")
				return
			end
			-- Strip optional markdown fences
			local stripped = text:match("```json%s*(.-)%s*```")
				or text:match("```%s*(.-)%s*```")
				or text
			stripped = stripped:gsub("^%s+",""):gsub("%s+$","")
			local buildData = dkjson.decode(stripped)
			if not buildData then
				self.aiStatus = "^1Error: Could not parse build JSON"
				ConPrintf("AI apply JSON (failed): %s", stripped:sub(1,300))
				return
			end
			self:ApplyBuildData(buildData)
		end,
		{ header = header, body = body }
	)
end

function AITabClass:ApplyBuildData(buildData)
	local build     = self.build
	local spec      = build.spec
	local skillsTab = build.skillsTab
	local applied   = {}

	-- Class
	local className = type(buildData.class) == "string" and buildData.class or nil
	if className then
		local classId = nil
		if spec.tree and spec.tree.classes then
			for cId, cData in pairs(spec.tree.classes) do
				if cData.name and cData.name:lower() == className:lower() then
					classId = cId break
				end
			end
		end
		classId = classId or CLASS_NAME_MAP[className:lower()]
		if classId ~= nil then
			spec:SelectClass(classId)
			t_insert(applied, "Class → " .. className)
			-- Ascendancy
			local ascendName = type(buildData.ascendancy) == "string" and buildData.ascendancy or nil
			if ascendName and ascendName:lower() ~= "none" and ascendName ~= "" then
				local curClass = spec.curClass
				if curClass and curClass.classes then
					for ascId, ascData in pairs(curClass.classes) do
						if ascId > 0 and ascData.name and ascData.name:lower() == ascendName:lower() then
							spec:SelectAscendClass(ascId)
							t_insert(applied, "Ascendancy → " .. ascendName)
							break
						end
					end
				end
			end
		else
			self.aiStatus = "^1Unknown class: " .. className
			return
		end
	end

	-- Gems
	local gems = type(buildData.gems) == "table" and buildData.gems or nil
	if gems and #gems > 0 then
		local gemList = {}
		local skipped = {}
		for _, gemName in ipairs(gems) do
			if type(gemName) == "string" and #gemName > 0 then
				local errMsg2, gemData = skillsTab:FindSkillGem(gemName)
				local canonName = gemData and gemData.name or gemName
				if not gemData then t_insert(skipped, gemName) end
				t_insert(gemList, {
					nameSpec = canonName, level = 20, quality = 0,
					qualityId = "Default", enabled = true, count = 1,
					enableGlobal1 = true, enableGlobal2 = false,
				})
			end
		end
		if #gemList > 0 then
			local socketGroup = {
				enabled = true, includeInFullDPS = false,
				label   = "AI: " .. (self.controls.promptInput.buf or "generated"),
				slot = "", source = "", mainActiveSkill = 1, mainActiveSkillCalcs = 1,
				gemList = gemList,
			}
			ConPrintf("AI Apply: socketGroupList length before insert = %d", #skillsTab.socketGroupList)
			t_insert(skillsTab.socketGroupList, socketGroup)
			ConPrintf("AI Apply: socketGroupList length after insert = %d", #skillsTab.socketGroupList)

			-- Update the list control selection
			local gl = skillsTab.controls.groupList
			if gl then
				gl.selIndex = #skillsTab.socketGroupList
				gl.selValue = socketGroup
				ConPrintf("AI Apply: groupList selIndex set to %d", gl.selIndex)
			else
				ConPrintf("AI Apply: WARNING controls.groupList is nil")
			end

			-- SetDisplayGroup initialises gem slots for editing (calls ProcessSocketGroup internally)
			local ok, err = pcall(function() skillsTab:SetDisplayGroup(socketGroup) end)
			if not ok then
				ConPrintf("AI Apply: SetDisplayGroup ERROR: %s", tostring(err))
				-- Fallback: call ProcessSocketGroup directly
				pcall(function() skillsTab:ProcessSocketGroup(socketGroup) end)
			else
				ConPrintf("AI Apply: SetDisplayGroup OK")
			end

			t_insert(applied, #gemList .. " gems added")
			if #skipped > 0 then
				ConPrintf("AI Apply: unrecognised gems: %s", table.concat(skipped, ", "))
			end
		end
	end

	-- Reinitialise the skill set so the Skills tab list control refreshes
	skillsTab:SetActiveSkillSet(skillsTab.activeSkillSetId)

	spec:AddUndoState()
	skillsTab:AddUndoState()
	build.buildFlag = true

	local sgCount = #skillsTab.socketGroupList
	ConPrintf("AI Apply: done. socketGroupList final length = %d", sgCount)
	for i, sg in ipairs(skillsTab.socketGroupList) do
		ConPrintf("AI Apply:  [%d] label='%s' gems=%d", i, sg.label or "", #(sg.gemList or {}))
	end

	-- Switch the view to Skills tab so the user can see the result
	build.viewMode = "SKILLS"

	self.aiStatus = #applied > 0
		and "^2Applied: " .. table.concat(applied, ", ") .. " - Skills tab opened"
		or  "^3Nothing was applied"
end

-- ================================================================
--  JSON string encoder
-- ================================================================
function jsonEncode(str)
	str = str:gsub('\\', '\\\\')
	str = str:gsub('"',  '\\"')
	str = str:gsub('\n', '\\n')
	str = str:gsub('\r', '\\r')
	str = str:gsub('\t', '\\t')
	return '"' .. str .. '"'
end
