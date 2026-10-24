-- =============================================
-- TRENCH CRUSADE UI EXTENDER (v0.5)
-- =============================================

local FACTIONS = {
    { name = "Default" },
    { name = "New Antioch" },
    { name = "Trench Pilgrims" },
    { name = "Iron Sultanate" },
    { name = "Heretic Legion" },
    { name = "Cult of the Black Grail" },
    { name = "Seven-Headed Serpent" }
}

local currentFactionIndex = 1 

local tcuiScript = [=[
-- =============================================
-- TRENCH CRUSADE UI FULL
-- =============================================

-- =============================================
-- Parts of the code are taken from Stabilized Bases v2.0.0 by @pyromaniacal
-- =============================================

--[[Stabilized Bases v2.0.0
    License (MIT):

    Copyright 2025 Pyromaniacal

    Permission is hereby granted, free of charge, to any person obtaining a copy of
    this software and associated documentation files (the "Software"), to deal in 
    the Software without restriction, including without limitation the rights to
    use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies 
    of the Software, and to permit persons to whom the Software is furnished to do 
    so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all 
    copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR 
    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, 
    FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL 
    THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER 
    LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, 
    OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN 
    THE SOFTWARE.
Report bugs to @pyromaniacal on Discord. My DMs are open, even if we don't share a server.
Script may or may not go up on github at some point.

Parts of the code are taken from GBee's Stabilizer v1.0.0.

On creation, the base will come with a snap point to enable placing models. This snap point is disabled when
a model is placed on the base and the base is lifted. The base, before having a model placed on it, will not 
stabilize dynamically. 
--]]

local factions_img = {
    { name = "Default", ready = "https://steamusercontent-a.akamaihd.net/ugc/17565077082788158933/75472FA5DF4D9A5A79DFCACCF02E6D044B0AB70F/"},
    { name = "The Principality of New Antioch", ready = "https://steamusercontent-a.akamaihd.net/ugc/12140870569665962018/647EDFF35D1397EC9577768D1913B378FD7F36CB/"},
    { name = "Trench Pilgrims", ready = "https://steamusercontent-a.akamaihd.net/ugc/10865693481180792483/AE8CC3A0A475582AAA8BB10EC12569BAC5AF6C1A/"},
    { name = "Iron Sultanate", ready = "https://steamusercontent-a.akamaihd.net/ugc/11011531862432102694/E93E2E25F8A724A188A450B906DFAA25E146F085/"},
    { name = "Heretic Legion", ready = "https://steamusercontent-a.akamaihd.net/ugc/11780656566766941905/005DCBF2BD729C494E5EC0DA58CF0398ABA447A8/"},
    { name = "Cult of the Black Grail", ready = "https://steamusercontent-a.akamaihd.net/ugc/15933842057862161695/5D24970A3042BDF9747BFC7DC74039B64C17BD99/"},
    { name = "Court of the Seven-Headed Serpent", ready = "https://steamusercontent-a.akamaihd.net/ugc/12527179569780597784/62EFCEC8605897141AC23B9F8E49A464589B2001/"}
}

-- =============================================
-- TRENCH CRUSADE UI + RANGE SYSTEM
-- =============================================

-- Global state variables
state = {
    activated = false, 
    blood = 0, 
    blessed = 0,
    infection = 0,
    showInfection = false,
    savePos = nil,  
    attachments = {},
	imgReady = nil
}
self.max_typed_number = 1

local CIRCLE_STEPS = 64
local typed_buffer = ""
local active_distance = 0
local timer_id = "range_input_timer"

-- Table of player colors converted to RGBA (from 0 to 1)
local player_colors = {
    White  = {r = 1, g = 1, b = 1, a = 0.9},
    Brown  = {r = 0.44, g = 0.23, b = 0.05, a = 0.9},
    Red    = {r = 0.85, g = 0.1, b = 0.1, a = 0.9},
    Orange = {r = 0.96, g = 0.39, b = 0.11, a = 0.9},
    Yellow = {r = 0.9, g = 0.9, b = 0.17, a = 0.9},
    Green  = {r = 0.11, g = 0.53, b = 0.11, a = 0.9},
    Teal   = {r = 0.12, g = 0.53, b = 0.53, a = 0.9},
    Blue   = {r = 0.11, g = 0.25, b = 0.76, a = 0.9},
    Purple = {r = 0.52, g = 0.1, b = 0.72, a = 0.9},
    Pink   = {r = 0.96, g = 0.44, b = 0.81, a = 0.9},
    Grey   = {r = 0.5, g = 0.5, b = 0.5, a = 0.9},
    Black  = {r = 0.1, g = 0.1, b = 0.1, a = 0.9}
}

function initializeTCUI(params)
    local ownerColor = (params and params.color) or "White"
    state = {
        owner = ownerColor, 
        activated = false, 
        blood = 0, 
        blessed = 0,
        infection = 0,
        showInfection = false,
        savePos = nil, 
        attachments = {},
		imgReady = (params and factions_img[params.currentFaction_id].ready)
    }
    self.addTag("TCUIOperative")
    	createSnapPoint()
    createUI()
    refreshUI()
end

function onLoad()
	createSnapPoint()
    if self.script_state ~= "" then
        local decoded = JSON.decode(self.script_state)
        if decoded then state = decoded end
    end
    
    if state.attachments == nil then state.attachments = {} end
    if state.infection == nil then state.infection = 0 end
    if state.showInfection == nil then state.showInfection = false end

    self.clearContextMenu()
    self.addContextMenuItem("Save Position", function() savePosition() end)
    self.addContextMenuItem("Load Position", function() loadPosition() end)
    self.addContextMenuItem("Toggle Infection", function() toggleInfection() end)
    self.addContextMenuItem("Clear Tokens", function() state.attachments = {} createUI() refreshUI() end)
    self.addContextMenuItem("Enable Snapping", createSnapPoint)
    self.addContextMenuItem("Disable Snapping", disableSnapPoint)
    
	if state.imgReady == nil then
        initializeTCUI() 
    end

    Wait.frames(function()
        if self ~= nil then 
            createUI() 
            refreshUI() 
            stabilize()
            --refreshVectors()
        end
    end, 5)
end

function saveState() self.script_state = JSON.encode(state) end

-- =============================================
-- TOKEN COLLISION LOGIC (v0.4)
-- =============================================

isColliding = false

function onCollisionEnter(a)
    -- Base check: whether processing is active, object exists, or if it is locked
    	Wait.frames(stabilize, 10)
	
    if isColliding or a.collision_object == nil or a.collision_object.getLock() then return end

    local obj = a.collision_object
    -- Check for token tags
    if obj.hasTag("TCUITokenSimple") or obj.hasTag("TCUITokenEquipment") then
        isColliding = true
        
        -- Get token data
        local tokenName = obj.getName() ~= "" and obj.getName() or obj.getDescription()
        local imageUrl = obj.getCustomObject().image
        local isEquipment = obj.hasTag("TCUITokenEquipment")
        
        -- Destroy physical object in the world
        obj.destruct() 

        -- Simplified logic: add or update token as active
        state.attachments[tokenName] = { 
            name = tokenName, 
            url = imageUrl, 
            equipment = isEquipment, 
            active = true
        }
        
        broadcastToAll("Token added to " .. self.getName() .. ": " .. tokenName, {0.2, 0.8, 0.2})
        
        -- Refresh UI
        createUI()
        refreshUI()
        saveState()
        
        -- Prevent double triggering for 20 frames
        Wait.frames(function() isColliding = false end, 20)
    end
end

-- =============================================
-- RANGE LOGIC
-- =============================================


-- Triggers when any player types a number over the object
function onNumberTyped(player_color, number, alt)
    Timer.destroy(timer_id)
    
    typed_buffer = typed_buffer .. tostring(number)
    
    if string.len(typed_buffer) > 2 then
        typed_buffer = string.sub(typed_buffer, -2)
    end

    -- 0.8 seconds buffer window to type the second digit
    Timer.create({
        identifier = timer_id,
        function_name = "commitTypedNumber",
        function_owner = self,
        parameters = {player_color = player_color},
        delay = 0.8
    })
    
    return true -- Blocks default TTS hotkey behavior
end

-- Processes the final number after the typing delay ends
function commitTypedNumber(params)
    local final_number = tonumber(typed_buffer)
    typed_buffer = "" -- Reset buffer
    
    if final_number == nil then return end
    
    local player_color = params.player_color
    local line_color = player_colors[player_color] or {r = 0, g = 1, b = 0, a = 0.9}
	local modelName = self.getName() ~= "" and self.getName() or "Unnamed Model"
	
    -- If typed 0 or the same number is typed again — clear the line
    if final_number == 0 or active_distance == final_number then
        clearLines()
        broadcastToAll(modelName .. ": Range cleared", {0.8, 0.8, 0.8})
        return
    end

    active_distance = final_number
    drawRangeShape(final_number, line_color)
    
	broadcastToAll(modelName .. ": Range set to " .. final_number .. " inch(es)", player_color)
end

-- Dynamic drawing (handles round, oval, and square bases)
function drawRangeShape(distance_inches, line_color)
    local scale = self.getScale()
    local bounds = self.getBounds()
    
    local size_x = bounds.size.x
    local size_z = bounds.size.z
    
    if size_x == 0 or size_z == 0 then
        size_x = 1.25 * scale.x
        size_z = 1.25 * scale.z
    end

    local base_radius_x = (size_x / 2) / scale.x
    local base_radius_z = (size_z / 2) / scale.z

    local total_radius_x = base_radius_x + (distance_inches / scale.x)
    local total_radius_z = base_radius_z + (distance_inches / scale.z)

    local points = {}
    for i = 0, CIRCLE_STEPS do
        local angle = (i * 2 * math.pi) / CIRCLE_STEPS
        table.insert(points, {
            x = math.cos(angle) * total_radius_x,
            y = 0.1, 
            z = math.sin(angle) * total_radius_z
        })
    end

    self.setVectorLines({
        {
            points    = points,
            color     = line_color,
            thickness = 0.06,
            loop      = true,
            square    = false
        }
    })
end

function clearLines()
    active_distance = 0
    typed_buffer = ""
    self.setVectorLines({})
end

-- =============================================
-- UI & STABILIZATION
-- =============================================

function createUI()
    Timer.destroy("TCUI_Init_" .. self.getGUID())

    Timer.create({
        identifier = "TCUI_Init_" .. self.getGUID(),
        function_name = "executeCreateUI",
        delay = 0.1
    })
end

function executeCreateUI()
    if state == nil then state = {} end
    if state.attachments == nil then state.attachments = {} end
    if self == nil or self.UI == nil then return end
	
    local assets = {
        {name="img_ready", url=state.imgReady}
    }
    
    local tokensXml = ""
    local tokenCount = 0
    if state.attachments then
        for name, att in pairs(state.attachments) do
            if att.active then
                local assetName = "at_" .. att.name
                table.insert(assets, {name=assetName, url=att.url})
                
                local xPos = (tokenCount * 65) - 65 
                -- Replacing Image with Button for interactivity
                tokensXml = tokensXml .. [[
                    <Button 
                        onClick="removeToken(]]..name..[[)" 
                        rectAlignment="MiddleCenter" 
                        offsetXY="]]..xPos..[[ -90" 
                        width="60" 
                        height="60" 
                        backgroundColor="#00000000" 
                        colors="#FFFFFF00|#FFFFFF00|#FFFFFF00|#FFFFFF00">
        
                        <Image 
                            image="]]..assetName..[[" 
                            width="60" 
                            height="60" 
                            preserveAspect="true" />
                    </Button>]]
    
                tokenCount = tokenCount + 1
            end
        end
    end

    local infectionXml = ""
    if state.showInfection then
        infectionXml = [[<Button class="invisible_clicker" onClick="handleInfectionClick" rectAlignment="MiddleCenter" offsetXY="-160 0" width="70" height="70">
            <Text id="infection" class="counter_text" color="#C7DF24" text="0"/></Button>]]
    end
	
    if self == nil or self.UI == nil then return end
	
    local finalXml = ""
    finalXml = [[
        		<Defaults>
            <Button class="invisible_clicker" backgroundColor="#00000000" colors="#00000000|#00000000|#00000000|#00000000" />
            <Text class="counter_text" fontSize="40" fontStyle="Bold" alignment="MiddleCenter" shadowColor="#000000BB" shadowDistance="2 -2" ignoreLayout="true"/>
        </Defaults>

        <Panel position="0 -150 -250" width="400" height="400">
            ]] .. tokensXml .. [[
            ]] .. infectionXml .. [[
            
            <!-- State Button (Center) -->
            <Button id="state_btn" onClick="toggleState" rectAlignment="MiddleCenter" offsetXY="0 0" width="70" height="70" backgroundColor="#00000000">
                <Image id="state_img" image="img_ready" />
            </Button>

            <!-- Blood (Left) -->
            <Button class="invisible_clicker" onClick="handleBloodClick" rectAlignment="MiddleCenter" offsetXY="-80 0" width="50" height="50">
                <Text id="blood" class="counter_text" color="#DC143C" text="0"/>
            </Button>

            <!-- Blessed (Right) -->
            <Button class="invisible_clicker" onClick="handleBlessedClick" rectAlignment="MiddleCenter" offsetXY="80 0" width="50" height="50">
                <Text id="blessed" class="counter_text" color="#20B2AA" text="0"/>
            </Button>
        </Panel>
    ]]

    local status = pcall(function()
        self.UI.setCustomAssets(assets)
        self.UI.setXml(finalXml)
    end)

    if not status then
        createUI()
        return
    end

    Wait.frames(function() refreshUI() end, 5)
end

-- Refresh function to locate and update elements
function refreshUI()
    if self == nil or self.UI == nil then return end
    pcall(function()
        if self.UI == nil or self.UI.getXml() == "" then return end

        local tintColor = state.activated and "#777777" or "#FFFFFF"
        self.UI.setAttribute("state_img", "color", tintColor)
        self.UI.setValue("blood", tostring(state.blood))
        self.UI.setValue("blessed", tostring(state.blessed))
        if state.showInfection then 
            self.UI.setValue("infection", tostring(state.infection or 0)) 
        end
    end)
    saveState()
end

function removeToken(player, tokenName)
    if state.attachments[tokenName] then
        state.attachments[tokenName].active = false
        broadcastToAll("Token removed: " .. tokenName, {0.8, 0.2, 0.2})
        
        -- Fully redraw UI to hide token
        createUI()
        refreshUI()
        saveState()
    end
end

function toggleInfection()
    state.showInfection = not state.showInfection
    createUI()
    refreshUI()
end

function handleInfectionClick(p, btn)
    state.infection = state.infection or 0

    if btn == "-1" then state.infection = math.min(6, state.infection + 1)
    elseif btn == "-2" then state.infection = math.max(0, state.infection - 1) end
    refreshUI()
end

function handleBloodClick(p, btn)
    if btn == "-1" then state.blood = math.min(6, state.blood + 1)
    elseif btn == "-2" then state.blood = math.max(0, state.blood - 1) end
    refreshUI()
end

function handleBlessedClick(p, btn)
    if btn == "-1" then state.blessed = math.min(6, state.blessed + 1)
    elseif btn == "-2" then state.blessed = math.max(0, state.blessed - 1) end
    refreshUI()
end

function toggleState() 
    state.activated = not state.activated 
    refreshUI() 
end

function createSnapPoint()
    self.setSnapPoints({
        {
            position = {0,0,0},
            rotation = {0,0,0},
            rotation_snap = true
        }
    })
end 
 
 function disableSnapPoint()
	self.setSnapPoints({})
end

function onPickUp(player_color) destabilize() end

function stabilize()
    local rb = self.getComponent("Rigidbody")
    rb.set("freezeRotation", true)
end

function destabilize()
    local rb = self.getComponent("Rigidbody")
    rb.set("freezeRotation", false)
end           

function savePosition()
    state.savePos={position=self.getPosition(), rotation=self.getRotation()}
    saveState()
end

function loadPosition()
    if state.savePos then
        self.setPositionSmooth(state.savePos.position)
        self.setRotationSmooth(state.savePos.rotation)
    end
end
]=]

local tcuiScriptShort = [=[
-- =============================================
-- TRENCH CRUSADE UI SHORT
-- =============================================

-- =============================================
-- Parts of the code are taken from Stabilized Bases v2.0.0 by @pyromaniacal
-- =============================================

--[[Stabilized Bases v2.0.0
    License (MIT):

    Copyright 2025 Pyromaniacal

    Permission is hereby granted, free of charge, to any person obtaining a copy of
    this software and associated documentation files (the "Software"), to deal in 
    the Software without restriction, including without limitation the rights to
    use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies 
    of the Software, and to permit persons to whom the Software is furnished to do 
    so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all 
    copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR 
    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, 
    FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL 
    THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER 
    LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, 
    OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN 
    THE SOFTWARE.
Report bugs to @pyromaniacal on Discord. My DMs are open, even if we don't share a server.
Script may or may not go up on github at some point.

Parts of the code are taken from GBee's Stabilizer v1.0.0.

On creation, the base will come with a snap point to enable placing models. This snap point is disabled when
a model is placed on the base and the base is lifted. The base, before having a model placed on it, will not 
stabilize dynamically. 
--]]

-- Global state variables
state = {
    savePos = nil
}
self.max_typed_number = 1

local CIRCLE_STEPS = 64
local typed_buffer = ""
local active_distance = 0
local timer_id = "range_input_timer"

-- Table of player colors converted to RGBA (from 0 to 1)
local player_colors = {
    White  = {r = 1, g = 1, b = 1, a = 0.9},
    Brown  = {r = 0.44, g = 0.23, b = 0.05, a = 0.9},
    Red    = {r = 0.85, g = 0.1, b = 0.1, a = 0.9},
    Orange = {r = 0.96, g = 0.39, b = 0.11, a = 0.9},
    Yellow = {r = 0.9, g = 0.9, b = 0.17, a = 0.9},
    Green  = {r = 0.11, g = 0.53, b = 0.11, a = 0.9},
    Teal   = {r = 0.12, g = 0.53, b = 0.53, a = 0.9},
    Blue   = {r = 0.11, g = 0.25, b = 0.76, a = 0.9},
    Purple = {r = 0.52, g = 0.1, b = 0.72, a = 0.9},
    Pink   = {r = 0.96, g = 0.44, b = 0.81, a = 0.9},
    Grey   = {r = 0.5, g = 0.5, b = 0.5, a = 0.9},
    Black  = {r = 0.1, g = 0.1, b = 0.1, a = 0.9}
}

function initializeTCRS(params)
    local ownerColor = (params and params.color) or "White"
    state = {
        owner = ownerColor, 
        savePos = nil
    }
    self.addTag("TCUIOperative")
    createSnapPoint()
end

function onLoad()
	createSnapPoint()
    if self.script_state ~= "" then
        local decoded = JSON.decode(self.script_state)
        if decoded then state = decoded end
    end
    
    self.clearContextMenu()
    self.addContextMenuItem("Save Position", function() savePosition() end)
    self.addContextMenuItem("Load Position", function() loadPosition() end)
    self.addContextMenuItem("Enable Snapping", createSnapPoint)
    self.addContextMenuItem("Disable Snapping", disableSnapPoint)
    
    initializeTCRS() 

    Wait.frames(function()
        if self ~= nil then 
            stabilize()
            --refreshVectors()
        end
    end, 5)
end

function saveState() self.script_state = JSON.encode(state) end

-- =============================================
-- RANGE LOGIC
-- =============================================

-- Triggers when any player types a number over the object
function onNumberTyped(player_color, number, alt)
    Timer.destroy(timer_id)
    
    typed_buffer = typed_buffer .. tostring(number)
    
    if string.len(typed_buffer) > 2 then
        typed_buffer = string.sub(typed_buffer, -2)
    end

    -- 0.8 seconds buffer window to type the second digit
    Timer.create({
        identifier = timer_id,
        function_name = "commitTypedNumber",
        function_owner = self,
        parameters = {player_color = player_color},
        delay = 0.8
    })
    
    return true -- Blocks default TTS hotkey behavior
end

-- Processes the final number after the typing delay ends
function commitTypedNumber(params)
    local final_number = tonumber(typed_buffer)
    typed_buffer = "" -- Reset buffer
    
    if final_number == nil then return end
    
    local player_color = params.player_color
    local line_color = player_colors[player_color] or {r = 0, g = 1, b = 0, a = 0.9}
	local modelName = self.getName() ~= "" and self.getName() or "Unnamed Model"
	
    -- If typed 0 or the same number is typed again — clear the line
    if final_number == 0 or active_distance == final_number then
        clearLines()
        broadcastToAll(modelName .. ": Range cleared", {0.8, 0.8, 0.8})
        return
    end

    active_distance = final_number
    drawRangeShape(final_number, line_color)
    
	broadcastToAll(modelName .. ": Range set to " .. final_number .. " inch(es)", player_color)
end

-- Dynamic drawing (handles round, oval, and square bases)
function drawRangeShape(distance_inches, line_color)
    local scale = self.getScale()
    local bounds = self.getBounds()
    
    local size_x = bounds.size.x
    local size_z = bounds.size.z
    
    if size_x == 0 or size_z == 0 then
        size_x = 1.25 * scale.x
        size_z = 1.25 * scale.z
    end

    local base_radius_x = (size_x / 2) / scale.x
    local base_radius_z = (size_z / 2) / scale.z

    local total_radius_x = base_radius_x + (distance_inches / scale.x)
    local total_radius_z = base_radius_z + (distance_inches / scale.z)

    local points = {}
    for i = 0, CIRCLE_STEPS do
        local angle = (i * 2 * math.pi) / CIRCLE_STEPS
        table.insert(points, {
            x = math.cos(angle) * total_radius_x,
            y = 0.1, 
            z = math.sin(angle) * total_radius_z
        })
    end

    self.setVectorLines({
        {
            points    = points,
            color     = line_color,
            thickness = 0.06,
            loop      = true,
            square    = false
        }
    })
end

function clearLines()
    active_distance = 0
    typed_buffer = ""
    self.setVectorLines({})
end

-- =============================================
-- STABILIZATION & SAVE/LOAD
-- =============================================


function createSnapPoint()
    self.setSnapPoints({
        {
            position = {0,0,0},
            rotation = {0,0,0},
            rotation_snap = true
        }
    })
end 
 
 function disableSnapPoint()
	self.setSnapPoints({})
end

function onPickUp(player_color) destabilize() end
function onCollisionEnter(self, info) Wait.frames(stabilize, 10) end

function stabilize()
    local rb = self.getComponent("Rigidbody")
    rb.set("freezeRotation", true)
end

function destabilize()
    local rb = self.getComponent("Rigidbody")
    rb.set("freezeRotation", false)
end           

function savePosition()
    state.savePos={position=self.getPosition(), rotation=self.getRotation()}
    saveState()
end

function loadPosition()
    if state.savePos then
        self.setPositionSmooth(state.savePos.position)
        self.setRotationSmooth(state.savePos.rotation)
    end
end
]=]

-- =============================================
-- CONTROLLER LOGIC (Setup Station)
-- =============================================

function ExtendTCUI(clicked_object, player_color)
    local models = getModelsOnMe()
    if #models == 0 then
        broadcastToColor("Place models ON the controller!", player_color, {1, 0.5, 0})
        return
    end
    	
    ClearAllTCUI(clicked_object, player_color)

    Wait.time(function()
    	local freshModels = getModelsOnMe()
	   	for _, obj in ipairs(freshModels) do
			obj.setLuaScript(tcuiScript)
		    Wait.time(function()
				if obj ~= nil then 
					obj.call("initializeTCUI", {color = player_color, currentFaction_id = currentFactionIndex}) 
					obj.call("onLoad", {color = player_color})
				end
		    end, 1)
	    end
	    broadcastToAll("TCUI: Updated " .. #freshModels .. " models.", {0.2, 1, 0.2})
  	end, 1.5)
end

function ExtendTCRS(clicked_object, player_color)
    local models = getModelsOnMe()
    if #models == 0 then
        broadcastToColor("Place models ON the controller!", player_color, {1, 0.5, 0})
        return
    end
    	
    ClearAllTCUI(clicked_object, player_color)

   	Wait.time(function()
  		local freshModels = getModelsOnMe()

   		for _, obj in ipairs(freshModels) do
	        obj.setLuaScript(tcuiScriptShort)
            Wait.time(function()
                if obj ~= nil then 
                    obj.call("initializeTCRS", {color = player_color})
                    obj.call("onLoad", {color = player_color}) 
                end
            end, 1)
        end
        broadcastToAll("TCUI: Updated " .. #freshModels .. " models.", {0.2, 1, 0.2})
   	end, 1.5)
end

function ClearAllTCUI(clicked_object, player_color)
    local models = getModelsOnMe()
    for _, obj in ipairs(models) do
        obj.setLuaScript("") 
        obj.UI.setXml("")    
        obj.reload() 
    end
    broadcastToAll("TCUI: Scripts removed.", {1, 0.3, 0.3})
end

function GlobalSavePositions()
    for _, obj in ipairs(getAllObjects()) do
        if obj.hasTag("TCUIOperative") then obj.call("savePosition") end
    end
    broadcastToAll("TCUI: Positions saved.", {0.2, 0.8, 1})
end

function GlobalLoadPositions()
    for _, obj in ipairs(getAllObjects()) do
        if obj.hasTag("TCUIOperative") then obj.call("loadPosition") end
    end
    broadcastToAll("TCUI: Positions restored.", {1, 0.8, 0.2})
end

function getModelsOnMe()
    local foundModels = {}
    local hits = Physics.cast({
        origin       = self.getPosition() + Vector(0, 0.5, 0),
        direction    = Vector(0, 1, 0),
        type         = 3,
        size         = self.getBounds().size,
        orientation  = self.getRotation(),
        max_distance = 2,
    })
    for _, hit in ipairs(hits) do
        local obj = hit.hit_object
        if obj ~= self and (obj.tag == "Figurine" or obj.hasTag("Model") or obj.hasTag("TCUIOperative")) then
            table.insert(foundModels, obj)
        end
    end
    return foundModels
end

function CycleFaction(clicked_object, player_color)
    currentFactionIndex = currentFactionIndex + 1
    if currentFactionIndex > #FACTIONS then
        currentFactionIndex = 1
    end
    
    local activeFaction = FACTIONS[currentFactionIndex]
    
    self.editButton({
        index = 0, 
        label = activeFaction.name
    })
    
    broadcastToColor("Selected Faction: " .. activeFaction.name, player_color, {0.2, 0.9, 0.9})
end

function onLoad()
	self.createButton({
        label="FACTION: Default", click_function="CycleFaction", function_owner=self,
        position={5.5, 0.6, 7.2}, width=2500, height=400, font_size=250,
        color={0.1, 0.1, 0.1}, font_color={0.2, 0.9, 0.9}
    })
    self.createButton({
        label="EXTEND TC UI", click_function="ExtendTCUI", function_owner=self,
        position={5.5, 0.6, 6}, width=2500, height=400, font_size=250,
        color={0.2, 0.5, 0.2}, font_color={1, 1, 1}
    })
    self.createButton({
        label="CLEAR SCRIPTS", click_function="ClearAllTCUI", function_owner=self,
        position={-5.5, 0.6, -7.2}, width=2500, height=400, font_size=250,
        color={0.5, 0.2, 0.2}, font_color={1, 1, 1}
    })
    self.createButton({
        label="SAVE ALL POS", click_function="GlobalSavePositions", function_owner=self,
        position={-5.5, 0.6, 6}, width=2500, height=400, font_size=250,
        color={0.2, 0.4, 0.6}, font_color={1, 1, 1}
    })
    self.createButton({
        label="LOAD ALL POS", click_function="GlobalLoadPositions", function_owner=self,
        position={-5.5, 0.6, 7.2}, width=2500, height=400, font_size=250,
        color={0.8, 0.5, 0.1}, font_color={1, 1, 1}
    })
    	self.createButton({
        label="EXTEND RANGE & SAVE", click_function="ExtendTCRS", function_owner=self,
        position={5.5, 0.6, 4.8}, width=2500, height=400, font_size=250,
        color={0.5, 0.5, 0.5}, font_color={1, 1, 1}
    })
end
