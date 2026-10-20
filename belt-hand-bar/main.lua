-- belt-&-hand-bar v1.0.3 - Gubber
local SLOT = {
  {name="Left hand", accepted={"left hand","lhand","lefthand","left_hand","left-hand","6l"}, index=6},
  {name="Right hand", accepted={"right hand","rhand","righthand","right_hand","right-hand","6r"}, index=7},
  {name="Belt", accepted={"belt","waist","5r"}, index=5},
}
local CELL, GAP, PAD, HANDLE = 44, 4, 3, 20
local W = PAD * 2 + CELL * 3 + GAP * 2
local H = PAD * 2 + CELL + HANDLE
local Y = PAD + HANDLE

local visible = {{}, {}, {}}
local bar = hafen.ui():widget()
  :size(W, H)
  :position(220, 170)
  :visible(true)

local grip = hafen.ui():widget():parent(bar):size(W, HANDLE):position(0, 0)
bar:draggable(grip)
bar:remember("equipment-quickbar-layout-v103")

local function normalize(value)
  return string.lower(tostring(value)):gsub("^%s+", ""):gsub("%s+$", "")
end

local function matches(item, accepted)
  for _, raw in ipairs(item:slots() or {}) do
    local value = normalize(raw)
    for _, name in ipairs(accepted) do
      if value == name then return true end
    end
  end
  return false
end

local function collect()
  local nextVisible = {{}, {}, {}}
  local session = hafen.session():current()
  if not session then visible=nextVisible; return end
  local equip = session:ui():equipment()
  if not equip or not equip:exists() then visible=nextVisible; return end
  for _, item in ipairs(equip:items():list()) do
    if item:exists() then
      for i, entry in ipairs(SLOT) do
        if matches(item, entry.accepted) then
          if not nextVisible[i].item then
            nextVisible[i] = {item=item, res=item:res()}
          end
        end
      end
    end
  end
  visible = nextVisible
end


-- Mouse input belongs to the addon layer, while equipment belongs to the
-- character's UI tree. Only queue indices during input; perform ALL cross-tree
-- reads and writes in the Update step. The old mouse handler read the cursor
local queued = {}
local lastStatus = nil
local statusUntil = 0
local clock = 0
local errors = 0
local elapsed = 0

local function status(message)
  lastStatus = message
  statusUntil = clock + 4
  hafen.log():write("Equipment Quickbar: " .. message)
end

local function cursorItem(session)
  local hand = session:player():hand()
  return hand and hand:item() or nil
end

local function actOnSlot(index)
  local session = hafen.session():current()
  if not session then status("No active session"); return end
  local equip = session:ui():equipment()
  if not equip or not equip:exists() then status("No equipment widget"); return end
  local carried = cursorItem(session)
  if carried then
    local wid = equip:id()
    if not wid then status("Equipment widget has no server ID"); return end
    local target = SLOT[index]
    local res = carried:res() or "?"
    status("Attempt equip: " .. target.name .. " (#" .. target.index .. ") / Equipory ID=" .. tostring(wid) .. " / cursor=" .. res)
    equip:send("drop", target.index)
  else
    collect()
    local item = visible[index] and visible[index].item
    if item and item:exists() and item:handle() then
      item:take()
      status("Picked up from " .. SLOT[index].name)
    else
      status(SLOT[index].name .. " empty; pick up an item first")
    end
  end
end

bar:on("Update", function(dt)
  local seconds = tonumber(dt) or 0.05
  clock = clock + seconds
  -- Handle queued mouse gestures FIRST, without the 200ms repaint throttle.
  local requests = queued
  queued = {}
  for _, index in ipairs(requests) do
    local ok, err = pcall(actOnSlot, index)
    if not ok then status("Action error: " .. tostring(err)) end
  end
  elapsed = elapsed + seconds
  if elapsed >= 0.20 then
    elapsed = 0
    local ok, err = pcall(collect)
    if not ok and errors < 3 then
      errors=errors+1
      status("Read error: " .. tostring(err))
    end
  end
end)

bar:on("Draw", function(event)
  local g = event:g()
  -- Everything stays strictly inside the W x H widget rectangle.
  -- Solid backing hides the game scene, preserving legibility.
  g:color(18, 18, 17, 255)
  g:frect(0, 0, W, H)

  -- Separate 20px drag handle, with an inset grip.
  g:color(58, 48, 32, 255)
  g:frect(0, 0, W, HANDLE)
  g:color(191, 150, 77, 255)
  local gripX = math.floor((W - 26) / 2)
  for k = 0, 2 do
    g:frect(gripX, 5 + k * 4, 26, 2)
  end

  for i = 1, 3 do
    local x = PAD + (i - 1) * (CELL + GAP)
    local y = Y
    -- 44px cells, exactly aligned with the click hitbox.
    g:color(14, 14, 13, 255)
    g:frect(x, y, CELL, CELL)
    local res = visible[i] and visible[i].res
    if res then
      g:color()
      g:resource(res, x + 6, y + 6, 32, 32)
    end
    g:color(175, 134, 70, 255)
    g:frect(x, y, CELL, 1)
    g:frect(x, y + CELL - 1, CELL, 1)
    g:frect(x, y, 1, CELL)
    g:frect(x + CELL - 1, y, 1, CELL)
  end
  g:color()
end)

local function selectedAt(x, y)
  if y < Y or y >= Y + CELL then return nil end
  for i=1,3 do
    local left = PAD + (i-1) * (CELL + GAP)
    if x >= left and x < left + CELL then return i end
  end
  return nil
end

bar:on("MouseDown", function(event)
  if event:button() ~= 1 then return end
  local index = selectedAt(event:x(), event:y())
  if not index then return end
  event:preventDefault()
  -- No cross-tree cursor read here! Queue for Update.
  queued[#queued+1] = index
end)

-- Compare the REAL outgoing message from the game's own Equipment window.
-- The addon message may travel a different route; this shows exactly what
-- successful native drop sends, without changing or cancelling anything.
hafen.event():action():on("drop", function(event)
  local widget = event:widget()
  if not widget or widget:type() ~= "Equipory" then return end
  local args = event:args()
  local parts = {}
  for i = 1, #args do parts[#parts + 1] = tostring(args[i]) end
  hafen.log():write("Equipment Quickbar: NATIVE Equipory drop ID=" .. tostring(widget:id()) .. " args=[" .. table.concat(parts, ",") .. "]")
end)

hafen.log():write("Equipment Quickbar v1.0.3 by Gubber loaded")
