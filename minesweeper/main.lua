-- Minesweeper Popper v1.1.2 -- Gubber
-- Cavewarn strength byte scale was field-tested at 1, 2, 3 and 4.

local TILE = 11
local RESOURCE = "gfx/fx/cavewarn"
local MAX_LIVE = 1500                  -- recent unsaved/current-session markers
local PER_GRID_LIMIT = 3500            -- per-nearby-grid memory/query guard
local MAX_PROJECTED = 1800            -- safety guard for busy mines

local options = hafen.client():options():addon()
local show_numbers = options:boolean("show-numbers"):default(true):add()
local save_tiles = options:boolean("save-tiles"):default(true):add()
local show_saved = options:boolean("show-saved"):default(true):add()
local radius_setting = options:number("radius-tiles"):range(10, 50):default(28):add()

local database = hafen.store()
local tiles = database:table("cavewarn_tiles")
  :column("grid", "text")
  :column("tx", "integer")
  :column("ty", "integer")
  :column("number", "integer")
  :key("grid", "tx", "ty")
  :create()

local live = {}           
local live_order = {}      
local nearby = {}         
local pending = {}       
local projected = {}       
local last_area = nil
local last_session = nil
local read_warned = false
local save_warned = false
local syncWorldOverlay

local function log(message)
  hafen.log():write("Minesweeper Popper: " .. message)
end

local function keyFor(grid, tx, ty)
  return grid .. ":" .. tostring(tx) .. ":" .. tostring(ty)
end

local function placeFor(grid, tx, ty)
  return {gridId=grid, x=tx * TILE + TILE/2, y=ty * TILE + TILE/2}
end

local function decodeCount(bytes)
  if type(bytes) ~= "table" or #bytes < 5 then return nil end
  local first = tonumber(bytes[1])
  if not first or first < 0 or first > 255 or first ~= math.floor(first) then return nil end
  local number = math.floor(first / 32) + 1
  if number < 1 or number > 8 then return nil end
  if math.abs(first - (32 * number - 1)) > 1 then return nil end
  return number
end

local function flushPending()
  if not save_tiles:value() then
    pending = {}
    return
  end
  local batch = pending
  pending = {}
  for _, record in pairs(batch) do
    local ok, failure = pcall(function()
      local older = tiles:get(record.grid, record.tx, record.ty)
      if older == nil or (tonumber(older.number) or 0) < record.n then
        tiles:put{grid=record.grid, tx=record.tx, ty=record.ty, number=record.n}
      end
    end)
    if not ok and not save_warned then
      save_warned = true
      log("Could not save tile: " .. tostring(failure))
    end
  end
end

local function onDust(gob, members)
  if not gob or not gob:exists() or type(members) ~= "table" then return end
  local position = gob:position()
  local info = position and position:info()
  if not info or info.gridId == nil or info.x == nil or info.y == nil then return end

  local grid = tostring(info.gridId)
  local tx, ty = math.floor(info.x / TILE), math.floor(info.y / TILE)
  if tx < 0 or tx > 99 or ty < 0 or ty > 99 then return end
  local key = keyFor(grid, tx, ty)

  for _, bytes in ipairs(members) do
    local number = decodeCount(bytes)
    if number then
      local previous = live[key] or nearby[key]
      -- Mining dust can update the same tile several times. Retain the highest value rather than replacing it with a weaker effect.
      local best = math.max(number, previous and previous.n or 0)
      local existing = live[key]
      if not existing then
        if #live_order >= MAX_LIVE then
          local removed = table.remove(live_order, 1)
          live[removed] = nil
        end
        live_order[#live_order+1] = key
        existing = {grid=grid, tx=tx, ty=ty, n=best, place=placeFor(grid, tx, ty)}
        live[key] = existing
      elseif best > existing.n then
        existing.n = best
      end
      if save_tiles:value() then
        local to_write = pending[key]
        if not to_write or to_write.n < best then
          pending[key] = {grid=grid, tx=tx, ty=ty, n=best}
        end
      end
    end
  end
end

local function process(gob)
  if not gob or not gob:exists() then return end
  local overlay = gob:overlay():get(RESOURCE)
  local state = overlay and overlay:sdt()
  if state then onDust(gob, state) end
end

local function resetTransient()
  live, live_order, nearby, pending, projected = {}, {}, {}, {}, {}
  last_area = nil
end

local function refreshNearby(player_position)
  if not show_saved:value() then
    nearby = {}
    last_area = nil
    return
  end
  local radius = radius_setting:value()
  local center = player_position:info()
  if not center or center.gridId == nil or center.x == nil or center.y == nil then return end
  local area = tostring(center.gridId) .. ":" .. math.floor(center.x / (TILE * 7))
    .. ":" .. math.floor(center.y / (TILE * 7)) .. ":" .. tostring(radius)
  if area == last_area then return end

  local bounds = {}
  local radius_world = radius * TILE
  local margin = 10                  -- covers motion between 7-tile reloads
  for _, dx in ipairs({-radius_world, 0, radius_world}) do
    for _, dy in ipairs({-radius_world, 0, radius_world}) do
      local sample = player_position:offset(dx, dy)
      local info = sample and sample:info()
      if info and info.gridId ~= nil and info.x ~= nil and info.y ~= nil then
        local grid = tostring(info.gridId)
        if not bounds[grid] then
          local local_cx = info.x - dx
          local local_cy = info.y - dy
          local minx = math.max(0, math.floor((local_cx-radius_world)/TILE)-margin)
          local maxx = math.min(99, math.floor((local_cx+radius_world)/TILE)+margin)
          local miny = math.max(0, math.floor((local_cy-radius_world)/TILE)-margin)
          local maxy = math.min(99, math.floor((local_cy+radius_world)/TILE)+margin)
          if minx <= maxx and miny <= maxy then
            bounds[grid] = {minx=minx, maxx=maxx, miny=miny, maxy=maxy}
          end
        end
      end
    end
  end

  local found = {}
  local ok, failure = pcall(function()
    for grid, box in pairs(bounds) do
      -- Bounds are already radius-aware and include a movement margin.
      local rows = tiles:list(
        "WHERE grid = ? AND tx BETWEEN ? AND ? AND ty BETWEEN ? AND ? LIMIT " .. PER_GRID_LIMIT,
        grid, box.minx, box.maxx, box.miny, box.maxy)
      for _, row in ipairs(rows) do
        local n = tonumber(row.number)
        if n and n >= 1 and n <= 8 then
          local key = keyFor(grid, row.tx, row.ty)
          found[key] = {grid=grid, tx=row.tx, ty=row.ty, n=n,
                        place=placeFor(grid, row.tx, row.ty)}
        end
      end
    end
  end)
  if ok then
    nearby = found
    last_area = area
  elseif not read_warned then
    read_warned = true
    log("Unable to load saved tiles: " .. tostring(failure))
  end
end

local function updateProjection(session)
  if not show_numbers:value() then projected = {}; return end
  local player = session:player():gob()
  local player_position = player and player:position()
  if not player_position then projected = {}; return end
  refreshNearby(player_position)
  local world = session:world()
  local center_x, center_y = player_position:x(), player_position:y()
  if center_x == nil or center_y == nil then projected = {}; return end
  local radius_world = radius_setting:value() * TILE
  local out, used = {}, {}

  local function add(record)
    local key = keyFor(record.grid, record.tx, record.ty)
    if used[key] or #out >= MAX_PROJECTED then return end
    used[key] = true
    local position = world:position(record.place)
    if not position then return end
    local x, y = position:x(), position:y()
    if not x or not y then return end
    if math.abs(x-center_x) > radius_world or math.abs(y-center_y) > radius_world then return end
    local point = world:worldToScreen(position)
    if point and point.x and point.y then
      out[#out+1] = {x=point.x, y=point.y, n=record.n}
    end
  end

  for _, key in ipairs(live_order) do
    local record = live[key]
    local saved = show_saved:value() and nearby[key] or nil
    if record and saved and saved.n > record.n then record = saved end
    if record then add(record) end
  end
  if show_saved:value() then
    for key, record in pairs(nearby) do
      if not live[key] then add(record) end
    end
  end
  projected = out
end

options:panel(function(root)
  root:gap(6)
  hafen.ui():label():parent(root):text("Minesweeper Popper | by Gubber")
  hafen.ui():label():parent(root):text("Cave tile numbers and saved observations")
  hafen.ui():check():parent(root):text("Show tile numbers"):bind(show_numbers)
  hafen.ui():check():parent(root):text("Save newly observed tiles"):bind(save_tiles)
  hafen.ui():check():parent(root):text("Display tiles saved from previous sessions"):bind(show_saved)

  local distance_label = hafen.ui():label():parent(root)
    :text("Display distance: " .. tostring(radius_setting:value()) .. " tiles")
  local distance_slider = hafen.ui():slider():parent(root):size(200):bind(radius_setting)
  distance_slider:on("Changed", function(event)
    distance_label:text("Display distance: " .. tostring(event:value()) .. " tiles")
    last_area = nil
  end)

  local count_label = hafen.ui():label():parent(root)
    :text("Saved tiles: " .. tostring(tiles:count()))
  hafen.ui():label():parent(root):text("Saved tile data is shared across characters on this client.")
  hafen.ui():label():parent(root):text("Deleting saved tiles cannot be undone.")
  local confirmation = false
  local button = hafen.ui():button():parent(root):size(220):text("Clear all saved tile data")
  button:on("Pressed", function()
    if not confirmation then
      confirmation = true
      button:text("CONFIRM: delete all saved tiles")
      return
    end
    confirmation = false
    local ok, removed = pcall(function() return database:exec("DELETE FROM cavewarn_tiles") end)
    if ok then
      resetTransient()
      count_label:text("Saved tiles: 0")
      log("Cleared " .. tostring(removed) .. " saved tile rows")
    else
      log("Could not clear saved tiles: " .. tostring(removed))
    end
    button:text("Clear all saved tile data")
  end)
end)

radius_setting:on("Changed", function() last_area = nil end)
show_saved:on("Changed", function()
  nearby, last_area = {}, nil
end)
save_tiles:on("Changed", function(value)
  if not value then pending = {} end
end)

hafen.event():on("SessionEnteredWorld", function(entered)
  -- Another logged-in character reaching the world should not erase the
  -- current character's live observations.
  if entered == hafen.session():current() then
    flushPending()
    resetTransient()
  end
end)
hafen.event():on("SessionRemoved", function(removed)
  if removed == last_session then
    flushPending()
    resetTransient()
    last_session = nil
  end
end)
hafen.event():on("GobAdded", function(gob)
  process(gob)
end)
hafen.event():on("GobOverlayAdded", function(event)
  if event:native() and event:key() == RESOURCE then process(event:gob()) end
end)
hafen.event():on("GobOverlaySdtChanged", function(event)
  if event:key() == RESOURCE then onDust(event:gob(), event:sdt()) end
end)

local last_flush = 0
hafen.event():on("Update", function(dt)
  local session = hafen.session():current()
  if session ~= last_session then
    flushPending()
    resetTransient()
    last_session = session
  end

  last_flush = last_flush + (tonumber(dt) or 0.05)
  if last_flush >= 0.30 then
    last_flush = 0
    flushPending()
  end
  syncWorldOverlay(session)
  if session then
    local ok, failure = pcall(updateProjection, session)
    if not ok then
      projected = {}
      if not read_warned then
        read_warned = true
        log("Projection error: " .. tostring(failure))
      end
    end
  else
    projected = {}
  end
end)

-- World-view overlays are painted after MapView and before HUD windows.
local attached_view = nil
local view_origin_x, view_origin_y = 0, 0
local attach_warned = false

local function drawTileNumbers(graphics, width, height)
  for _, record in ipairs(projected) do
    local x, y = record.x - view_origin_x, record.y - view_origin_y
    if x >= 0 and y >= 0 and x < width and y < height then
      local number = tostring(record.n)
      graphics:color(0,0,0,255)
      graphics:atext(number,x-1,y,0.5,0.5)
      graphics:atext(number,x+1,y,0.5,0.5)
      graphics:atext(number,x,y-1,0.5,0.5)
      graphics:atext(number,x,y+1,0.5,0.5)
      if record.n == 1 then graphics:color(110,180,255,255)
      elseif record.n == 2 then graphics:color(110,255,130,255)
      elseif record.n == 3 then graphics:color(255,180,75,255)
      elseif record.n == 4 then graphics:color(255,95,95,255)
      else graphics:color(255,80,170,255) end
      graphics:atext(number,x,y,0.5,0.5)
    end
  end
  graphics:color()
end

syncWorldOverlay = function(session)
  if not session then
    attached_view = nil
    return
  end

  local ok, failure = pcall(function()
    local view = session:ui():match("@MapView")
    if not view or not view:exists() then
      attached_view = nil
      return
    end
    local origin = view:rootPos()
    if not origin then
      attached_view = nil
      return
    end
    if view ~= attached_view then
      view:overlay():add("minesweeper-popper-numbers"):draw(drawTileNumbers)
      attached_view = view
    end
    view_origin_x, view_origin_y = origin.x, origin.y
  end)
  if not ok then
    attached_view = nil
    if not attach_warned then
      attach_warned = true
      log("Could not attach numbers below windows: " .. tostring(failure))
    end
  end
end

log("v1.1.2 loaded: tile numbers now draw on MapView, under chat/inventory/map windows; saved tile database unchanged")
