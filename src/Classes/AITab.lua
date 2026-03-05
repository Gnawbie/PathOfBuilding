-- AI Build Advisor Tab
-- Place this file in: src/Classes/AITab.lua

local t_insert = table.insert
local t_remove = table.remove
local m_floor = math.floor

local AITabClass = newClass("AITab", "ControlHost", "Control", function(self, build)
	self:ControlHostInit()
	self:ControlInit(build)
	self.build = build

	-- State
	self.aiStatus = ""
	self.aiResponse = ""
	self.apiKey = main.aiAPIKey or ""
	self.requesting = false

	-- === API Key section ===
	self.controls.apiKeyLabel = new("LabelControl", {"TOPLEFT",self,""}, 20, 20, 0, 16,
		"^7Anthropic API Key:")

	self.controls.apiKeyInput = new("EditControl", {"TOPLEFT",self.controls.apiKeyLabel,"BOTTOMLEFT"}, 0, 4, 400, 20,
		self.apiKey, nil, nil, nil, function(buf)
			self.apiKey = buf
			main.aiAPIKey = buf
			main:SaveSettings()
		end)
	self.controls.apiKeyInput.password = true

	self.controls.apiKeySaveNote = new("LabelControl", {"LEFT",self.controls.apiKeyInput,"RIGHT"}, 8, 0, 0, 16,
		"^8Saved automatically to settings")

	-- === Prompt section ===
	self.controls.promptLabel = new("LabelControl", {"TOPLEFT",self.controls.apiKeyInput,"BOTTOMLEFT"}, 0, 20, 0, 16,
		"^7Describe the build you want:")

	self.controls.promptInput = new("EditControl", {"TOPLEFT",self.controls.promptLabel,"BOTTOMLEFT"}, 0, 4, 600, 20,
		"", "e.g. tanky lightning strike slayer, or fire dot elementalist", nil, 500)

	-- === Generate button ===
	self.controls.generateBtn = new("ButtonControl", {"TOPLEFT",self.controls.promptInput,"BOTTOMLEFT"}, 0, 10, 140, 22,
		"Generate Build", function()
			self:SendRequest()
		end)
	self.controls.generateBtn.enabled = function()
		return not self.requesting and #self.apiKey > 0 and #self.controls.promptInput.buf > 0
	end

	-- === Context toggle ===
	self.controls.includeContextChk = new("CheckBoxControl", {"LEFT",self.controls.generateBtn,"RIGHT"}, 12, 0, 18,
		"Include current build as context", function(state)
			self.includeContext = state
		end)
	self.controls.includeContextChk.state = true
	self.includeContext = true

	-- === Status label ===
	self.controls.statusLabel = new("LabelControl", {"TOPLEFT",self.controls.generateBtn,"BOTTOMLEFT"}, 0, 8, 0, 16,
		function() return self.aiStatus end)

	-- === Response display ===
	self.controls.responseLabel = new("LabelControl", {"TOPLEFT",self.controls.statusLabel,"BOTTOMLEFT"}, 0, 6, 0, 16,
		"^7Response:")

	self.controls.responseBox = new("EditControl", {"TOPLEFT",self.controls.responseLabel,"BOTTOMLEFT"}, 0, 4, 700, 400,
		"", nil, nil, nil, nil)
	self.controls.responseBox.readOnly = true

	-- === Copy button ===
	self.controls.copyBtn = new("ButtonControl", {"TOPLEFT",self.controls.responseBox,"BOTTOMLEFT"}, 0, 8, 100, 20,
		"Copy Response", function()
			Copy(self.aiResponse)
		end)
	self.controls.copyBtn.enabled = function()
		return #self.aiResponse > 0
	end

	-- === Clear button ===
	self.controls.clearBtn = new("ButtonControl", {"LEFT",self.controls.copyBtn,"RIGHT"}, 8, 0, 80, 20,
		"Clear", function()
			self.aiResponse = ""
			self.aiStatus = ""
			self.controls.responseBox:SetText("")
		end)
end)

function AITabClass:Draw(viewPort, inputEvents)
	self.x = viewPort.x
	self.y = viewPort.y
	self.width = viewPort.width
	self.height = viewPort.height

	self:DrawControls(viewPort, inputEvents)
end

function AITabClass:BuildContext()
	-- Serialise current build state into a compact context string for the prompt
	local build = self.build
	local lines = {}

	-- Class and ascendancy
	local className = build.spec.curClassName or "Unknown"
	local ascendName = build.spec.curAscendClassName or "None"
	t_insert(lines, "Class: " .. className .. " / Ascendancy: " .. ascendName)

	-- Level
	t_insert(lines, "Level: " .. (build.characterLevel or 1))

	-- Main skill
	local mainGroup = build.skillsTab.socketGroupList[build.mainSocketGroup]
	if mainGroup then
		local skillNames = {}
		for _, gem in ipairs(mainGroup.gemList) do
			if gem.nameSpec then
				t_insert(skillNames, gem.nameSpec)
			end
		end
		t_insert(lines, "Main skill group: " .. table.concat(skillNames, " + "))
	end

	-- Key stats from calc output
	local output = build.calcsTab.mainOutput
	if output then
		if output.Life then
			t_insert(lines, "Life: " .. m_floor(output.Life))
		end
		if output.EnergyShield and output.EnergyShield > 0 then
			t_insert(lines, "Energy Shield: " .. m_floor(output.EnergyShield))
		end
		if output.TotalDPS then
			t_insert(lines, "Total DPS: " .. m_floor(output.TotalDPS))
		end
	end

	-- Allocated passive count
	local nodeCount = 0
	for _ in pairs(build.spec.allocNodes) do
		nodeCount = nodeCount + 1
	end
	t_insert(lines, "Allocated passives: " .. nodeCount)

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

	-- Build the message content
	local userMessage = prompt
	if self.includeContext then
		local ctx = self:BuildContext()
		userMessage = "Current build context:\n" .. ctx .. "\n\nRequest: " .. prompt
	end

	local systemPrompt = [[You are an expert Path of Exile build advisor. When given a build request, provide:
1. A clear build concept summary (2-3 sentences)
2. Recommended class and ascendancy
3. Core skill gems (main 6-link)
4. Key passive tree priorities (major nodes/clusters to aim for)
5. Essential unique items
6. Stat priorities for rare items
Be specific and practical. Format your response clearly with these sections.]]

	-- Construct JSON body
	local requestBody = string.format(
		'{"model":"claude-sonnet-4-20250514","max_tokens":1500,"system":%s,"messages":[{"role":"user","content":%s}]}',
		jsonEncode(systemPrompt),
		jsonEncode(userMessage)
	)

	-- Make the HTTP request using lcurl
	local curl = require("lcurl.safe")
	local responseChunks = {}

	local easy = curl.easy()
	easy:setopt_url("https://api.anthropic.com/v1/messages")
	easy:setopt_httpheader({
		"Content-Type: application/json",
		"x-api-key: " .. self.apiKey,
		"anthropic-version: 2023-06-01",
	})
	easy:setopt_postfields(requestBody)
	easy:setopt_writefunction(function(chunk)
		t_insert(responseChunks, chunk)
		return true
	end)

	-- Use launch's async download mechanism so we don't freeze the UI
	launch:DoOnFrameCallback(function()
		local ok, err = easy:perform()
		easy:close()

		if not ok then
			self.aiStatus = "^1Request failed: " .. tostring(err)
			self.requesting = false
			return
		end

		local responseText = table.concat(responseChunks)
		self:HandleResponse(responseText)
		self.requesting = false
	end)
end

function AITabClass:HandleResponse(responseText)
	-- Parse the JSON response from Anthropic API
	-- Response format: {"content":[{"type":"text","text":"..."}],...}
	local text = responseText:match('"text"%s*:%s*"(.-[^\\])"')
	if text then
		-- Unescape JSON string escapes
		text = text:gsub('\\"', '"')
		text = text:gsub('\\n', '\n')
		text = text:gsub('\\t', '\t')
		text = text:gsub('\\\\', '\\')
		self.aiResponse = text
		self.controls.responseBox:SetText(text)
		self.aiStatus = "^2Done!"
	else
		-- Check for error response
		local errMsg = responseText:match('"message"%s*:%s*"(.-[^\\])"')
		if errMsg then
			self.aiStatus = "^1API Error: " .. errMsg
		else
			self.aiStatus = "^1Error: Could not parse response"
		end
	end
end

-- Simple JSON string encoder
function jsonEncode(str)
	str = str:gsub('\\', '\\\\')
	str = str:gsub('"', '\\"')
	str = str:gsub('\n', '\\n')
	str = str:gsub('\r', '\\r')
	str = str:gsub('\t', '\\t')
	return '"' .. str .. '"'
end
