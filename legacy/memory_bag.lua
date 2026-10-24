-- Memory Bag - Area-based Save/Recall

memoryList = {}
memoryListBackup = {}

-- ===================== CONFIG =====================
local AREA_SIZE       = {x=100, y=8, z=100}
local AREA_OFFSET     = {x=53,  y=2, z=0}
local ONLY_MODELS     = true
local HIGHLIGHT_COLOR = {0,1,0}
local BATCH_SIZE      = 20    -- keeps takeObject calls from overwhelming TTS all at once
local BATCH_DELAY     = 0.1   -- short wait between batches for TTS to catch up
-- ==================================================

local isBusy       = false
local placeBatches = {}

function updateSave()
    self.script_state = JSON.encode({ml=memoryList})
end

function onload(saved_data)
    memoryList = (saved_data ~= "") and JSON.decode(saved_data).ml or {}
    if next(memoryList) == nil then createSetupButton() else createMemoryActionButtons() end
end

-- ============ SETUP ============
function createSetupButton()
    self.createButton({label="Setup (Area)", click_function="buttonClick_setup", function_owner=self,
        position={0,0.3,-2}, rotation={0,180,0}, height=350, width=1200, font_size=250, color={0,0,0}, font_color={1,1,1}})
end

function buttonClick_setup()
    memoryListBackup = duplicateTable(memoryList)
    memoryList = {}
    self.clearButtons()
    createAreaSelection()
    createSetupActionButtons()
end

function createAreaSelection()
    local bagPos = self.getPosition()
    local half   = {x=AREA_SIZE.x/2, y=AREA_SIZE.y/2, z=AREA_SIZE.z/2}
    local center = {x=bagPos.x+AREA_OFFSET.x, y=bagPos.y+AREA_OFFSET.y, z=bagPos.z+AREA_OFFSET.z}
    local count  = 0
    for _, obj in ipairs(getAllObjects()) do
        if obj ~= self and isValidObject(obj) then
            local p = obj.getPosition()
            if math.abs(p.x-center.x) <= half.x and
               math.abs(p.y-center.y) <= half.y and
               math.abs(p.z-center.z) <= half.z then
                local pos, rot = obj.getPosition(), obj.getRotation()
                memoryList[obj.getGUID()] = {
                    pos  = {x=round(pos.x,4), y=round(pos.y,4), z=round(pos.z,4)},
                    rot  = {x=round(rot.x,4), y=round(rot.y,4), z=round(rot.z,4)},
                    lock = obj.getLock()
                }
                obj.highlightOn(HIGHLIGHT_COLOR)
                count = count + 1
            end
        end
    end
    broadcastToAll("Area Setup Complete - "..count.." objects saved", {1,1,1})
end

function isValidObject(obj)
    if not obj then return false end
    local t = obj.getType() or ""
    return not (ONLY_MODELS and (t=="Card" or t=="Deck" or t=="Dice" or t=="Coin"))
end

function createSetupActionButtons()
    self.createButton({label="Cancel", click_function="buttonClick_cancel", function_owner=self,
        position={0,0.3,-2}, rotation={0,180,0}, height=350, width=1100, font_size=250, color={0,0,0}, font_color={1,1,1}})
    self.createButton({label="Submit", click_function="buttonClick_submit", function_owner=self,
        position={0,0.3,-2.8}, rotation={0,180,0}, height=350, width=1100, font_size=250, color={0,0,0}, font_color={1,1,1}})
    self.createButton({label="Reset", click_function="buttonClick_reset", function_owner=self,
        position={-2,0.3,0}, rotation={0,270,0}, height=350, width=800, font_size=250, color={0,0,0}, font_color={1,1,1}})
end

function createMemoryActionButtons()
    self.createButton({label="Place", click_function="buttonClick_place", function_owner=self,
        position={0,0.3,-2}, rotation={0,180,0}, height=350, width=800, font_size=250, color={0,0,0}, font_color={1,1,1}})
    self.createButton({label="Recall", click_function="buttonClick_recall", function_owner=self,
        position={0,0.3,-2.8}, rotation={0,180,0}, height=350, width=800, font_size=250, color={0,0,0}, font_color={1,1,1}})
    self.createButton({label="Setup", click_function="buttonClick_setup", function_owner=self,
        position={-2,0.3,0}, rotation={0,270,0}, height=350, width=800, font_size=250, color={0,0,0}, font_color={1,1,1}})
end

function buttonClick_cancel()
    memoryList = memoryListBackup
    self.clearButtons()
    removeAllHighlights()
    if next(memoryList) == nil then createSetupButton() else createMemoryActionButtons() end
end

function buttonClick_submit()
    if next(memoryList) == nil then
        broadcastToAll("No objects in area!", {0.75,0.25,0.25})
        return
    end
    self.clearButtons()
    createMemoryActionButtons()
    removeAllHighlights()
    updateSave()
    broadcastToAll("Objects Saved", {1,1,1})
end

function buttonClick_reset()
    memoryList = {}
    self.clearButtons()
    removeAllHighlights()
    createSetupButton()
    updateSave()
end

-- ============ RECALL ============
function buttonClick_recall()
    if isBusy then return end
    isBusy = true

    local bagPos = self.getPosition()
    for guid, _ in pairs(memoryList) do
        local obj = getObjectFromGUID(guid)
        if obj then
            -- If object is on top of or inside the bag, nudge it clear first
            local op = obj.getPosition()
            local dx, dy, dz = op.x-bagPos.x, op.y-bagPos.y, op.z-bagPos.z
            if math.sqrt(dx*dx + dy*dy + dz*dz) < 3 then
                obj.setPosition({bagPos.x, bagPos.y+4, bagPos.z})
            end
            self.putObject(obj)
        end
    end

    isBusy = false
    broadcastToAll("Objects Recalled", {1,1,1})
end

-- ============ PLACE (batched) ============
function buttonClick_place()
    if isBusy or next(memoryList) == nil then return end
    isBusy = true

    placeBatches = {}
    local batch = {}
    for guid, entry in pairs(memoryList) do
        table.insert(batch, {guid=guid, entry=entry})
        if #batch >= BATCH_SIZE then
            table.insert(placeBatches, batch)
            batch = {}
        end
    end
    if #batch > 0 then table.insert(placeBatches, batch) end

    broadcastToAll("Placing objects...", {1,1,1})
    processNextBatch()
end

function processNextBatch()
    if #placeBatches == 0 then
        isBusy = false
        broadcastToAll("Objects Placed", {1,1,1})
        return
    end

    local batch = table.remove(placeBatches, 1)
    local bagContents = self.getObjects()

    for _, item in ipairs(batch) do
        local guid, entry = item.guid, item.entry
        local obj = getObjectFromGUID(guid)
        if obj then
            obj.setPosition(entry.pos)
            obj.setRotation(entry.rot)
            obj.setLock(entry.lock)
        else
            for _, bagObj in ipairs(bagContents) do
                if bagObj.guid == guid then
                    local taken = self.takeObject({
                        guid     = guid,
                        position = entry.pos,
                        rotation = entry.rot,
                        smooth   = false,
                    })
                    if taken then taken.setLock(entry.lock) end
                    break
                end
            end
        end
    end

    Wait.time(processNextBatch, BATCH_DELAY)
end

-- ============ UTIL ============
function removeAllHighlights()
    for _, obj in ipairs(getAllObjects()) do obj.highlightOff() end
end

function duplicateTable(oldTable)
    local newTable = {}
    for k, v in pairs(oldTable) do newTable[k] = v end
    return newTable
end

function round(num, dec)
    local mult = 10^(dec or 0)
    return math.floor(num * mult + 0.5) / mult
end
