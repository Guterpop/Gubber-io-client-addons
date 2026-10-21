-- Better Quality Display v1.6.0, by Gubber
-- Uses native widget overlays, not nested label widgets: moving items rebuilds
-- their icons, and every icon gets a new overlay via item-role Added.
-- Native quality labels keep up with icon resizing and have no black plate.
-- The font has a real 1-pixel black glyph outline.

-- Quality tooltips can resolve after their icons are created, especially
-- after splitting a stack. Retry only icons whose quality is currently unknown.
-- Item:Changed remains the primary, immediate update mechanism.
local QUALITY_RETRY_SECONDS = 0.20
local QUALITY_MAX_RETRIES = 40  -- ~8 seconds; no permanent background polling

local QUALITY_KEY = "quality"
local QUALITY_FONT = hafen.font():get("sans"):derive():size(11):bold(true):outline{0, 0, 0}

-- Keep the existing RGB setting keys and controls.
local options = hafen.client():options():addon()
local red   = options:number("quality-red"):range(0, 255):default(255):add()
local green = options:number("quality-green"):range(0, 255):default(255):add()
local blue  = options:number("quality-blue"):range(0, 255):default(255):add()
local quickbarQuality = options:boolean("quality-on-quickbar"):default(true):add()

local function qualityColor()
  return {red:value(), green:value(), blue:value()}
end

-- Brodgar's addon export interface crosses only plain values/functions, not
-- Item or Font handles. The quickbar asks for this snapshot periodically.
-- With this addon disabled its exported API becomes nil, hiding quickbar Q.
hafen.client():addons():export({
  quickbarStyle = function()
    return {
      enabled = quickbarQuality:value(),
      color = qualityColor(),
    }
  end,
})

-- Track only the living icon overlays. The client destroys an icon on every
-- move and sends a new item Added event for its replacement.
local coloredIcons = {}    -- icon -> native quality Overlay
local colorTimer
local function recolorExisting()
  colorTimer = nil
  local color = qualityColor()
  for icon, overlay in pairs(coloredIcons) do
    if icon:exists() and overlay:exists() then
      overlay:color(color)
    else
      coloredIcons[icon] = nil
    end
  end
end

-- An option callback fires during Options UI updates. Defer the widget edits
-- by one step, as in Brodgar's official Hitboxes addon.
local function scheduleRecolor()
  if colorTimer then colorTimer:cancel() end
  colorTimer = hafen.timer():after(0, recolorExisting)
end

for _, option in ipairs({red, green, blue}) do
  option:on("Changed", scheduleRecolor)
end

local function slider(root, name, setting)
  local caption = hafen.ui():label():parent(root):text(name .. ": " .. tostring(setting:value()))
  local control = hafen.ui():slider():parent(root):size(190):bind(setting)
  control:on("Changed", function(event)
    caption:text(name .. ": " .. tostring(event:value()))
    scheduleRecolor()
  end)
end

options:panel(function(root)
  root:gap(5)
  hafen.ui():label():parent(root):text("Better Quality Display | by Gubber")
  hafen.ui():label():parent(root):text("Quality color (RGB, 0-255)")
  slider(root, "Red", red)
  slider(root, "Green", green)
  slider(root, "Blue", blue)
  hafen.ui():label():parent(root):text("White is 255 / 255 / 255. The black outline is always on.")
  hafen.ui():label():parent(root):text("Quality labels sit at each item's top-right corner.")
  hafen.ui():check():parent(root)
    :text("Show quality on Equipment Quickbar (when installed)")
    :bind(quickbarQuality)
end)

-- Wear indicator reproduced from the official item-indicators addon.
local WEAR_KEY = "wear"
local SCALE = hafen.ui():scale()
local function dev(n) return math.floor((n * SCALE) + 0.5) end
local BAR_MARGIN = dev(1)
local BAR_HEIGHT = dev(2)
local FRESH_COLOUR = {70, 200, 80}
local HALF_COLOUR = {235, 215, 70}
local WORN_COLOUR = {220, 60, 60}

local function mix(from, to, t)
  return {
    math.floor(from[1] + (to[1] - from[1]) * t + 0.5),
    math.floor(from[2] + (to[2] - from[2]) * t + 0.5),
    math.floor(from[3] + (to[3] - from[3]) * t + 0.5)
  }
end

local function wearColour(remaining)
  if remaining > 0.5 then
    return mix(HALF_COLOUR, FRESH_COLOUR, (remaining - 0.5) * 2)
  end
  return mix(WORN_COLOUR, HALF_COLOUR, remaining * 2)
end

local function screenRect(graphics, x, y, w, h)
  if w <= 0 or h <= 0 then return end
  graphics:poly(x / SCALE, y / SCALE, (x + w) / SCALE, y / SCALE,
    (x + w) / SCALE, (y + h) / SCALE, x / SCALE, (y + h) / SCALE)
end

local function drawMeter(graphics, width, height, lift, fraction, colour)
  local iconWidth = dev(width)
  local iconBottom = dev(height) - lift
  local troughWidth = iconWidth - 3 - (BAR_MARGIN * 2)
  if troughWidth < 3 then return end
  graphics:color(0, 0, 0, 255)
  screenRect(graphics, 1 + BAR_MARGIN, iconBottom - 3 - BAR_MARGIN - BAR_HEIGHT,
    troughWidth, BAR_HEIGHT + 2)
  screenRect(graphics, BAR_MARGIN, iconBottom - 2 - BAR_MARGIN - BAR_HEIGHT, 1, BAR_HEIGHT)
  screenRect(graphics, iconWidth - 2 - BAR_MARGIN, iconBottom - 2 - BAR_MARGIN - BAR_HEIGHT, 1, BAR_HEIGHT)
  local fillWidth = math.floor(fraction * (iconWidth - 2 - (BAR_MARGIN * 2))) - 1
  if fillWidth > 0 then
    graphics:color(colour)
    screenRect(graphics, 1 + BAR_MARGIN, iconBottom - 2 - BAR_MARGIN - BAR_HEIGHT, fillWidth, BAR_HEIGHT)
  end
  graphics:color()
end

local function remainingOf(item)
  local durability = item:durability()
  if durability == nil or durability.max == nil or durability.max <= 0 then return nil end
  local remaining = 1 - (durability.cur / durability.max)
  return math.max(0, math.min(1, remaining))
end

local function clientDrawsABar(item)
  local contents = item:contents()
  return contents ~= nil and contents:fill() ~= nil
end

local function stackHeight()
  return BAR_HEIGHT + 3
end

local subscriptions = {}

local function meanQuality(item)
  local contents = item:contents()
  if contents == nil then return nil end

  local total, count = 0, 0
  for _, part in ipairs(contents:items():list()) do
    local q = part:quality()
    if q ~= nil then
      total = total + q
      count = count + 1
    end
  end
  if count == 0 then return nil end
  return total / count
end

local function qualityOf(item)
  local contents = item:contents()
  if contents ~= nil then
    local q = meanQuality(item) or contents:quality()
    if q ~= nil then return q end
  end
  return item:quality()
end


local function decorateIcon(icon)
  -- Item icons are replaced on moves/splits. This callback runs for each new
  -- instance, and Changed watches its own tooltip as it becomes available.
  local item = icon:item()
  if item == nil or item:handle() == nil then return end

  local revisions
  local retryTimer
  local retryCount = 0
  local refresh

  local function stopRetry()
    if retryTimer ~= nil then
      retryTimer:cancel()
      retryTimer = nil
    end
  end

  -- This handles the brief gap between an icon appearing and its tooltip
  -- publishing a quality. It never invents a quality from the former stack:
  -- each resulting item must report its own value before we display one.
  local function retryMissingQuality()
    if retryTimer ~= nil or retryCount >= QUALITY_MAX_RETRIES then return end
    retryTimer = hafen.timer():after(QUALITY_RETRY_SECONDS, function()
      retryTimer = nil
      if not icon:exists() then return end
      retryCount = retryCount + 1
      refresh()
    end)
  end

  refresh = function()
    if not icon:exists() then
      stopRetry()
      coloredIcons[icon] = nil
      return
    end

    local q = qualityOf(item)
    if q == nil then
      -- A split stack can temporarily have no resolved tooltip. Clear any
      -- stale average while waiting for the new individual item's quality.
      if coloredIcons[icon] ~= nil then
        icon:overlay():remove(QUALITY_KEY)
        coloredIcons[icon] = nil
      end
      retryMissingQuality()
    else
      stopRetry()
      retryCount = 0
      local text = tostring(math.floor(q + 0.5))
      local overlay = icon:overlay():get(QUALITY_KEY)
      if overlay == nil then
        overlay = icon:overlay():add(QUALITY_KEY)
          :anchor(1, 0):offset(-1, 1)
          :color(qualityColor()):font(QUALITY_FONT)
      end
      overlay:text(text)
      coloredIcons[icon] = overlay
    end

    -- Keep the existing item wear meter entirely unchanged.
    local remaining = remainingOf(item)
    if remaining == nil then
      icon:overlay():remove(WEAR_KEY)
    else
      local lift = clientDrawsABar(item) and stackHeight() or 0
      local colour = wearColour(remaining)
      icon:overlay():add(WEAR_KEY):draw(function(graphics, width, height)
        drawMeter(graphics, width, height, lift, remaining, colour)
      end)
    end
  end

  refresh()
  if not icon:exists() then
    stopRetry()
    return
  end

  icon:on("Removed", function()
    stopRetry()
    if revisions ~= nil then revisions:off() end
    coloredIcons[icon] = nil
  end)

  revisions = item:on("Changed", function()
    -- A new tooltip revision gets a fresh retry window.
    retryCount = 0
    refresh()
  end)

  -- One extra look on the next UI step catches icons whose state was filled
  -- in during the tick in which they were announced. The recurring retries
  -- above run ONLY while quality is actually absent.
  hafen.timer():after(0, function()
    if icon:exists() then refresh() end
  end)
end

local function forgetSession(session)
  local sub = subscriptions[session]
  if sub then sub:off() subscriptions[session] = nil end
end

local function watchSession(session)
  forgetSession(session)
  subscriptions[session] = session:ui():on("item", "Added", decorateIcon)
end

hafen.event():on("SessionEnteredWorld", watchSession)
hafen.event():on("SessionRemoved", forgetSession)
