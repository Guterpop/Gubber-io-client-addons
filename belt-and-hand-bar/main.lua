-- Hand & Belt bar v1.2.1 - Gubber
-- Slot targets derived from the user's successful native Equipory drop logs:
-- Belt: 5, Left hand: 6, Right hand: 7.
-- Display slot names are sourced from item:slots(), independently of placement IDs.
local SLOT = {
  {name="Left hand", accepted={"left hand","lhand","lefthand","left_hand","left-hand","6l"}, index=6},
  {name="Right hand", accepted={"right hand","rhand","righthand","right_hand","right-hand","6r"}, index=7},
  {name="Belt", accepted={"belt","waist","5r"}, index=5},
}
-- A slimmer grip without reducing the original horizontal width or slot size.
local CELL, GAP, PAD, HANDLE = 44, 4, 3, 10
local options = hafen.client():options():addon()
local verticalOption = options:boolean("vertical-layout"):default(false):add()
options:panel(function(root)
  root:gap(5)
  hafen.ui():label():parent(root):text("Hand & Belt bar | by Gubber")
  hafen.ui():check():parent(root)
    :text("Vertical layout (stack the three slots)")
    :bind(verticalOption)
  hafen.ui():label():parent(root)
    :text("Drag the bar using the thin gold grip above its slots.")
end)

local vertical = verticalOption:value() == true
local function dimensions()
  local span = CELL * 3 + GAP * 2
  if vertical then return CELL + PAD * 2, HANDLE + PAD * 2 + span end
  return PAD * 2 + span, HANDLE + PAD * 2 + CELL
end
local W, H = dimensions()

-- Screen and input use the same pixel geometry in either orientation.
local function slotPosition(index)
  local step = (index - 1) * (CELL + GAP)
  if vertical then return PAD, HANDLE + PAD + step end
  return PAD + step, HANDLE + PAD
end

-- Integration is optional: keep displaying/operating the bar when Better
-- Quality Display is disabled, absent or not yet loaded.
local qualityAddon = hafen.client():addons():get("better-quality-display")
local qualityFont = hafen.font():get("sans"):derive():size(11):bold(true):outline{0, 0, 0}
local quickbarStyle = nil

local function readQualityStyle()
  local api = qualityAddon:api()
  if not api or type(api.quickbarStyle) ~= "function" then return nil end
  local ok, style = pcall(api.quickbarStyle)
  if not ok or type(style) ~= "table" or not style.enabled then return nil end
  local color = style.color
  if type(color) ~= "table" or type(color[1]) ~= "number" or
     type(color[2]) ~= "number" or type(color[3]) ~= "number" then return nil end
  return {color={color[1], color[2], color[3]}}
end

local visible = {{}, {}, {}}
-- No window => no Nordic Forge window frame, title bar or hidden extra padding.
local bar = hafen.ui():widget()
  :size(W, H)
  :position(220, 170)
  :visible(true)

-- The grip is the only drag target, leaving all equipment slots clickable.
local grip = hafen.ui():widget():parent(bar):size(W, HANDLE):position(0, 0)
bar:draggable(grip)
bar:remember("equipment-quickbar-layout-v103")

local function applyLayout()
  local desired = verticalOption:value() == true
  if vertical == desired then return end
  vertical = desired
  W, H = dimensions()
  -- Resize parent AND drag hitbox together; no extra inert rectangle.
  bar:size(W, H)
  grip:size(W, HANDLE)
end

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
  quickbarStyle = readQualityStyle()
  local nextVisible = {{}, {}, {}}
  local session = hafen.session():current()
  if not session then visible=nextVisible; return end
  local equip = session:ui():equipment()
  if not equip or not equip:exists() then visible=nextVisible; return end
  for _, item in ipairs(equip:items():list()) do
    if item:exists() then
      for i, entry in ipairs(SLOT) do
        if matches(item, entry.accepted) then
          -- Never replace a hand icon with a different equipped item during
          -- the same scan. An unmatched slot stays empty after unequipping.
          if not nextVisible[i].item then
            local q = nil
            if quickbarStyle then
              -- Worn equipment uses its OWN quality. For an equipped belt,
              -- do not average the contents of the belt's inventory.
              local raw = item:quality()
              if type(raw) == "number" and raw == raw and raw >= 0 then
                q = tostring(math.floor(raw + 0.5))
              end
            end
            nextVisible[i] = {item=item, res=item:res(), quality=q}
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
-- directly and could never execute the equip branch on a captured cursor.
local queued = {}
local lastStatus = nil
local statusUntil = 0
local clock = 0
local errors = 0
local elapsed = 0

local function status(message)
  lastStatus = message
  statusUntil = clock + 4
  hafen.log():write("Hand & Belt bar: " .. message)
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
    -- Do not assume accepted by server; retain cursor item until it confirms.
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
  -- Options may change in another UI tree; read the saved value on Update.
  applyLayout()
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

  -- Low-profile 10px handle, full bar width in either orientation.
  g:color(58, 48, 32, 255)
  g:frect(0, 0, W, HANDLE)
  g:color(191, 150, 77, 255)
  local gripX = math.floor((W - 26) / 2)
  g:frect(gripX, 3, 26, 1)
  g:frect(gripX, 6, 26, 1)

  for i = 1, 3 do
    local x, y = slotPosition(i)
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

    -- Own 11px outlined quality text in the icon's top-right. A text draw
    -- cannot accept an Item from another addon; the color comes from the
    -- exported plain-value style snapshot taken during Update.
    local shown = visible[i]
    if quickbarStyle and shown and shown.quality then
      g:color()
      g:atext(shown.quality, x + CELL - 3, y + 2, 1, 0,
        {font=qualityFont, color=quickbarStyle.color})
    end
  end
  g:color()
end)

local function selectedAt(x, y)
  for i = 1, 3 do
    local left, top = slotPosition(i)
    if x >= left and x < left + CELL and
       y >= top and y < top + CELL then return i end
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

hafen.log():write("Hand & Belt bar v1.2.1 by Gubber loaded")
