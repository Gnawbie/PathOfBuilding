-- AI Build Advisor Tab
-- Place this file in: src/Classes/AITab.lua

local t_insert = table.insert
local t_remove = table.remove
local m_floor = math.floor
local dkjson = require "dkjson"

local MODELS = {
	{ label = "Haiku  (Fast)",     id = "claude-3-5-haiku-20241022"   },
	{ label = "Sonnet (Balanced)", id = "claude-3-5-sonnet-20241022"  },
	{ label = "Opus   (Smart)",    id = "claude-3-opus-20240229"      },
}
local DEFAULT_MODEL = 2  -- Sonnet

-- Fallback class name→ID map (PoB's class IDs are stable)
local CLASS_NAME_MAP = {
	scion = 0, marauder = 1, ranger = 2,
	witch = 3, duelist = 4, templar = 5, shadow = 6,
}

local AITabClass = newClass("AITab", "ControlHost", "Control", function(self, build)
	self.ControlHost()
	self.Control()
	self.build = build

	-- State
	self.aiStatus = ""
	self.aiResponse = ""
	self.apiKey = main.aiAPIKey or ""
	self.requesting = false
	self.includeContext = true
	self.modelIndex = DEFAULT_MODEL

	-- === API Key section ===
	self.controls.apiKeyLabel = new("LabelControl", {"TOPLEFT",self,"TOPLEFT"}, {20, 20, 0, 16},
		"^7Anthropic API Key:")

	self.controls.apiKeyInput = new("EditControl", {"TOPLEFT",self.controls.apiKeyLabel,"BOTTOMLEFT"}, {0, 4, 400, 20},
		self.apiKey, nil, nil, nil, function(buf)
			self.apiKey = buf
			main.aiAPIKey = buf
			main:SaveSettings()
		end)
	self.controls.apiKeyInput:SetProtected(true)

	self.controls.apiKeySaveNote = new("LabelControl", {"LEFT",self.controls.apiKeyInput,"RIGHT"}, {8, 0, 0, 16},
		"^8Saved automatically to settings")

	-- === Model selector ===
	self.controls.modelLabel = new("LabelControl", {"TOPLEFT",self.controls.apiKeyInput,"BOTTOMLEFT"}, {0, 12, 0, 16},
		"^7Model:")

	local modelList = {}
	for _, m in ipairs(MODELS) do t_insert(modelList, m.label) end
	self.controls.modelDrop = new("DropDownControl", {"LEFT",self.controls.modelLabel,"RIGHT"}, {8, 0, 180, 20},
		modelList, function(index)
			self.modelIndex = index
		end)
	self.controls.modelDrop.selIndex = DEFAULT_MODEL

	-- === Prompt section ===
	self.controls.promptLabel = new("LabelControl", {"TOPLEFT",self.controls.modelLabel,"BOTTOMLEFT"}, {0, 12, 0, 16},
		"^7Describe the build you want:")

	self.controls.promptInput = new("EditControl", {"TOPLEFT",self.controls.promptLabel,"BOTTOMLEFT"}, {0, 4, 0, 20},
		"", "e.g. tanky lightning strike slayer, or fire dot elementalist", nil, 500)
	self.controls.promptInput.width = function()
		return self.width - 40
	end

	-- === Generate button + context toggle row ===
	self.controls.generateBtn = new("ButtonControl", {"TOPLEFT",self.controls.promptInput,"BOTTOMLEFT"}, {0, 10, 140, 22},
		"Generate Build", function()
			self:SendRequest()
		end)
	self.controls.generateBtn.enabled = function()
		return not self.requesting and #self.apiKey > 0 and #self.controls.promptInput.buf > 0
	end

	self.controls.includeContextChk = new("CheckBoxControl", {"TOPLEFT",self.controls.generateBtn,"BOTTOMLEFT"}, {220, 8, 18, 18},
		"Include current build as context", function(state)
			self.includeContext = state
		end, nil, true)

	-- === Status label ===
	self.controls.statusLabel = new("LabelControl", {"TOPLEFT",self.controls.includeContextChk,"BOTTOMLEFT"}, {-220, 6, 0, 16},
		function() return self.aiStatus end)

	-- === Response display (fills remaining tab space) ===
	self.controls.responseLabel = new("LabelControl", {"TOPLEFT",self.controls.statusLabel,"BOTTOMLEFT"}, {0, 4, 0, 16},
		"^7Response:")

	self.controls.responseBox = new("EditControl", {"TOPLEFT",self.controls.responseLabel,"BOTTOMLEFT"}, {0, 4, 0, 0},
		"", nil, nil, nil, nil, 16)
	self.controls.responseBox.width = function()
		return self.width - 40
	end
	self.controls.responseBox.height = function()
		return self.height - 320  -- leave room for buttons below
	end

	-- === Copy / Clear / Apply buttons ===
	self.controls.copyBtn = new("ButtonControl", {"TOPLEFT",self.controls.responseBox,"BOTTOMLEFT"}, {0, 6, 100, 20},
		"Copy Response", function()
			Copy(self.aiResponse)
		end)
	self.controls.copyBtn.enabled = function()
		return #self.aiResponse > 0
	end

	self.controls.clearBtn = new("ButtonControl", {"LEFT",self.controls.copyBtn,"RIGHT"}, {8, 0, 80, 20},
		"Clear", function()
			self.aiResponse = ""
			self.aiStatus = ""
			self.controls.responseBox:SetText("")
		end)

	self.controls.applyBtn = new("ButtonControl", {"LEFT",self.controls.clearBtn,"RIGHT"}, {8, 0, 160, 20},
		"Apply Build to PoB", function()
			self:ApplyBuild()
		end)
	self.controls.applyBtn.enabled = function()
		return not self.requesting and #self.aiResponse > 0
	end
end)

function AITabClass:Draw(viewPort, inputEvents)
	self.x = viewPort.x
	self.y = viewPort.y
	self.width = viewPort.width
	self.height = viewPort.height

	-- Sync API key from settings (loaded after AITab is constructed)
	if main.aiAPIKey ~= "" and self.apiKey ~= main.aiAPIKey then
		self.apiKey = main.aiAPIKey
		self.controls.apiKeyInput:SetText(main.aiAPIKey)
	end

	self:ProcessControlsInput(inputEvents, viewPort)
	main:DrawBackground(viewPort)
	self:DrawControls(viewPort)
end

function AITabClass:BuildContext()
	local build = self.build
	local lines = {}

	-- Class and ascendancy
	local className = build.spec.curClassName or "Unknown"
	local ascendName = build.spec.curAscendClassName or "None"
	t_insert(lines, "Class: " .. className .. " / Ascendancy: " .. ascendName)

	-- Level
	t_insert(lines, "Level: " .. (build.characterLevel or 1))

	-- Main skill group
	local mainGroup = build.skillsTab.socketGroupList[build.mainSocketGroup]
	if mainGroup then
		local skillNames = {}
		for _, gem in ipairs(mainGroup.gemList) do
			if gem.nameSpec then t_insert(skillNames, gem.nameSpec) end
		end
		t_insert(lines, "Main skill: " .. table.concat(skillNames, " + "))
	end

	-- Defence style and key stats
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
		-- Resistances
		local res = {}
		if output.FireResist    then t_insert(res, "Fire "  .. output.FireResist    .. "%") end
		if output.ColdResist    then t_insert(res, "Cold "  .. output.ColdResist    .. "%") end
		if output.LightningResist then t_insert(res, "Lightning " .. output.LightningResist .. "%") end
		if #res > 0 then t_insert(lines, "Resistances: " .. table.concat(res, ", ")) end
	end

	-- Keystones
	local keystones = {}
	for _, node in pairs(build.spec.allocNodes) do
		if node.isKeystone then
			t_insert(keystones, node.name)
		end
	end
	if #keystones > 0 then
		t_insert(lines, "Keystones: " .. table.concat(keystones, ", "))
	end

	-- Main hand weapon type
	local weaponSlot = build.itemsTab.items["Weapon 1"]
	if weaponSlot and weaponSlot.type then
		t_insert(lines, "Main hand: " .. weaponSlot.type)
	end

	-- Passive count
	local nodeCount = 0
	for _ in pairs(build.spec.allocNodes) do nodeCount = nodeCount + 1 end
	t_insert(lines, "Passive points used: " .. nodeCount)

	return table.concat(lines, "\n")
end

function AITabClass:SendRequest()
	if self.requesting then return end
	if #self.apiKey == 0 then
		self.aiStatus = "^1Error: No API key set"
		return
	end

	local prompt = self.controls.promptInput.buf
	if #prompt == 0 then
		self.aiStatus = "^1Error: No prompt entered"
		return
	end

	self.requesting = true
	self.aiStatus = "^xFFD700Sending request..."
	self.aiResponse = ""
	self.controls.responseBox:SetText("")

	local userMessage = prompt
	if self.includeContext then
		local ctx = self:BuildContext()
		userMessage = "Current build context:\n" .. ctx .. "\n\nRequest: " .. prompt
	end

	local systemPrompt = [[You are an expert Path of Exile build advisor embedded inside Path of Building. When given a build request, provide:
1. Build concept summary (2-3 sentences)
2. Recommended class and ascendancy
3. Core skill gems (main 6-link with support gems)
4. Key passive tree priorities (clusters and notable nodes to aim for)
5. Essential unique items
6. Stat priorities for rare items
Be specific, practical, and concise. If a current build context is provided, tailor advice to improve or pivot it.]]

	local model = MODELS[self.modelIndex] and MODELS[self.modelIndex].id or MODELS[DEFAULT_MODEL].id

	local requestBody = string.format(
		'{"model":%s,"max_tokens":1500,"system":%s,"messages":[{"role":"user","content":%s}]}',
		jsonEncode(model),
		jsonEncode(systemPrompt),
		jsonEncode(userMessage)
	)

	launch:DownloadPage(
		"https://api.anthropic.com/v1/messages",
		function(response, errMsg)
			self.requesting = false
			if errMsg then
				self.aiStatus = "^1Request failed: " .. errMsg
				return
			end
			self:HandleResponse(response.body)
		end,
		{
			header = "Content-Type: application/json\nx-api-key: " .. self.apiKey .. "\nanthropic-version: 2023-06-01",
			body = requestBody,
		}
	)
end

function AITabClass:HandleResponse(responseText)
	local data, _, err = dkjson.decode(responseText)
	if data and data.content and data.content[1] and data.content[1].text then
		local text = data.content[1].text
		self.aiResponse = text
		self.controls.responseBox:SetText(text)
		self.aiStatus = "^2Done! Click 'Apply Build to PoB' to apply gems and class."
	elseif data and data.error and data.error.message then
		self.aiStatus = "^1API Error: " .. data.error.message
	else
		self.aiStatus = "^1Error: Could not parse response"
		ConPrintf("AI raw response: %s", responseText:sub(1, 300))
	end
end

-- ============================================================
--  APPLY BUILD
-- ============================================================

function AITabClass:ApplyBuild()
	if self.requesting then return end
	if #self.aiResponse == 0 then
		self.aiStatus = "^1No response to apply"
		return
	end

	self.requesting = true
	self.aiStatus = "^xFFD700Extracting build data..."

	local extractPrompt = table.concat({
		"From the following Path of Exile build advice, extract a JSON object with exactly these fields:",
		"  \"class\": one of [Marauder, Ranger, Witch, Duelist, Templar, Shadow, Scion]",
		"  \"ascendancy\": the ascendancy subclass name, or \"None\" if not mentioned",
		"  \"gems\": an array of up to 6 gem name strings for the main skill link (active skill first, then supports)",
		"",
		"Rules:",
		"- Output ONLY valid JSON. No markdown, no explanation, no code fences.",
		"- Use exact PoB gem names where possible (e.g. \"Lightning Strike\", \"Multistrike Support\").",
		"- If the class is not clearly stated, infer it from the ascendancy.",
		"- If a field cannot be determined, use null for strings or [] for the gems array.",
		"",
		"Build advice:",
		self.aiResponse,
	}, "\n")

	local systemPrompt = "You extract structured data from Path of Exile build descriptions. Output ONLY valid JSON with no surrounding text."

	local model = MODELS[self.modelIndex] and MODELS[self.modelIndex].id or MODELS[DEFAULT_MODEL].id

	local requestBody = string.format(
		'{"model":%s,"max_tokens":400,"system":%s,"messages":[{"role":"user","content":%s}]}',
		jsonEncode(model),
		jsonEncode(systemPrompt),
		jsonEncode(extractPrompt)
	)

	launch:DownloadPage(
		"https://api.anthropic.com/v1/messages",
		function(response, errMsg)
			self.requesting = false
			if errMsg then
				self.aiStatus = "^1Apply failed: " .. errMsg
				return
			end
			self:HandleApplyResponse(response.body)
		end,
		{
			header = "Content-Type: application/json\nx-api-key: " .. self.apiKey .. "\nanthropic-version: 2023-06-01",
			body = requestBody,
		}
	)
end

function AITabClass:HandleApplyResponse(responseText)
	local data, _, err = dkjson.decode(responseText)
	if not (data and data.content and data.content[1] and data.content[1].text) then
		if data and data.error and data.error.message then
			self.aiStatus = "^1API Error: " .. data.error.message
		else
			self.aiStatus = "^1Error: Could not parse API response"
			ConPrintf("AI apply raw: %s", responseText:sub(1, 300))
		end
		return
	end

	local jsonText = data.content[1].text

	-- Strip markdown code fences if Claude wrapped the JSON anyway
	local stripped = jsonText:match("```json%s*(.-)%s*```")
		or jsonText:match("```%s*(.-)%s*```")
		or jsonText
	stripped = stripped:gsub("^%s+", ""):gsub("%s+$", "")

	local buildData, _, parseErr = dkjson.decode(stripped)
	if not buildData then
		self.aiStatus = "^1Error: Could not parse build JSON"
		ConPrintf("AI apply JSON (failed): %s", stripped:sub(1, 300))
		return
	end

	self:ApplyBuildData(buildData)
end

function AITabClass:ApplyBuildData(buildData)
	local build    = self.build
	local spec     = build.spec
	local skillsTab = build.skillsTab
	local applied  = {}

	-- ---- Class -------------------------------------------------------
	local className = type(buildData.class) == "string" and buildData.class or nil
	if className then
		-- Try tree.classes first (runtime data), fall back to hardcoded map
		local classId = nil
		if spec.tree and spec.tree.classes then
			for cId, cData in pairs(spec.tree.classes) do
				if cData.name and cData.name:lower() == className:lower() then
					classId = cId
					break
				end
			end
		end
		if classId == nil then
			classId = CLASS_NAME_MAP[className:lower()]
		end

		if classId ~= nil then
			spec:SelectClass(classId)
			t_insert(applied, "Class → " .. className)

			-- ---- Ascendancy ------------------------------------------
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
			ConPrintf("AI Apply: unknown class '%s'", className)
			self.aiStatus = "^1Unknown class: " .. className
			return
		end
	end

	-- ---- Gems --------------------------------------------------------
	local gems = type(buildData.gems) == "table" and buildData.gems or nil
	if gems and #gems > 0 then
		local gemList = {}
		local skipped = {}
		for _, gemName in ipairs(gems) do
			if type(gemName) == "string" and #gemName > 0 then
				-- Validate against PoB gem database
				local errMsg, gemData = skillsTab:FindSkillGem(gemName)
				if gemData then
					-- Use the canonical name from the database
					t_insert(gemList, {
						nameSpec       = gemData.name,
						level          = 20,
						quality        = 0,
						qualityId      = "Default",
						enabled        = true,
						count          = 1,
						enableGlobal1  = true,
						enableGlobal2  = false,
					})
				else
					-- Not found — still add by name so the user can see it
					t_insert(gemList, {
						nameSpec       = gemName,
						level          = 20,
						quality        = 0,
						qualityId      = "Default",
						enabled        = true,
						count          = 1,
						enableGlobal1  = true,
						enableGlobal2  = false,
					})
					t_insert(skipped, gemName)
				end
			end
		end

		if #gemList > 0 then
			local socketGroup = {
				enabled               = true,
				includeInFullDPS      = false,
				label                 = "AI: " .. (self.controls.promptInput.buf or "generated"),
				slot                  = "",
				source                = "",
				mainActiveSkill       = 1,
				mainActiveSkillCalcs  = 1,
				gemList               = gemList,
			}

			-- Append to the active socket group list
			t_insert(skillsTab.socketGroupList, socketGroup)
			skillsTab:ProcessSocketGroup(socketGroup)

			local gemNames = {}
			for _, g in ipairs(gemList) do t_insert(gemNames, g.nameSpec) end
			t_insert(applied, #gemList .. " gems added")

			if #skipped > 0 then
				ConPrintf("AI Apply: unrecognised gems (added anyway): %s", table.concat(skipped, ", "))
			end
		end
	end

	-- ---- Save undo state + trigger recalc ----------------------------
	skillsTab:AddUndoState()
	build.buildFlag = true

	if #applied > 0 then
		self.aiStatus = "^2Applied: " .. table.concat(applied, ", ") .. "  (check Skills tab)"
	else
		self.aiStatus = "^3Nothing was applied (class/gems not found in response)"
	end
end

-- ============================================================
--  Simple JSON string encoder (used when building request body)
-- ============================================================
function jsonEncode(str)
	str = str:gsub('\\', '\\\\')
	str = str:gsub('"', '\\"')
	str = str:gsub('\n', '\\n')
	str = str:gsub('\r', '\\r')
	str = str:gsub('\t', '\\t')
	return '"' .. str .. '"'
end
