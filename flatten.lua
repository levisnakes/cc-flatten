-- flatten.lua : mining turtle clears an area down to its own level and
-- patches holes in the floor with the stone/dirt it mined.
--
-- Usage: flatten <length> <width> [height|auto] [left] [nofill]
--   Stand the turtle ON the floor you want (it clears its own level and up),
--   at one corner, facing along the length. The area goes forward <length>
--   and to the right <width> (add "left" to go left instead).
--   height = how many levels to clear (default auto: keeps going up until a
--   whole layer is empty). Put a chest BEHIND the turtle for it to unload into.

local args = { ... }

local function usage()
  print("Usage: flatten <length> <width> [height|auto] [left] [nofill]")
  print("Stand turtle on the floor level, at a corner,")
  print("facing along the length. Area goes forward and")
  print("to the right. Chest behind it = unload spot.")
end

if not turtle then print("This has to run on a turtle.") return end

local L, W = tonumber(args[1]), tonumber(args[2])
if not L or not W or L < 1 or W < 1 then usage() return end
L, W = math.floor(L), math.floor(W)

local H, AUTO, MIRROR, FILL = 256, true, false, true
for i = 3, #args do
  local a = args[i]:lower()
  if tonumber(a) then H = math.floor(tonumber(a)) AUTO = false
  elseif a == "left" then MIRROR = true
  elseif a == "nofill" then FILL = false
  elseif a ~= "auto" then usage() return end
end
if H < 1 then usage() return end

local MAX_FILL_DEPTH = 6     -- how deep a hole it will climb into and fill
local KEEP_FILLER = 128      -- filler blocks kept when unloading

local FILLER = {
  ["minecraft:cobblestone"] = true, ["minecraft:cobbled_deepslate"] = true,
  ["minecraft:dirt"] = true, ["minecraft:coarse_dirt"] = true,
  ["minecraft:stone"] = true, ["minecraft:deepslate"] = true,
  ["minecraft:andesite"] = true, ["minecraft:diorite"] = true,
  ["minecraft:granite"] = true, ["minecraft:tuff"] = true,
  ["minecraft:netherrack"] = true, ["minecraft:sandstone"] = true,
  ["minecraft:calcite"] = true, ["minecraft:blackstone"] = true,
}

-- position relative to start: x = forward, z = toward the width side, y = up
-- facing: 0 = +x, 1 = +z, 2 = -x, 3 = -z
local x, y, z, f = 0, 0, 0, 0
local dug, placed = 0, 0

local function fuel()
  local l = turtle.getFuelLevel()
  if l == "unlimited" then return math.huge end
  return l
end

local function right()
  if MIRROR then turtle.turnLeft() else turtle.turnRight() end
  f = (f + 1) % 4
end
local function left()
  if MIRROR then turtle.turnRight() else turtle.turnLeft() end
  f = (f + 3) % 4
end
local function face(d)
  if (d - f) % 4 == 3 then left() else while f ~= d do right() end end
end

local function stuck(where, why)
  error(("Can't dig %s at %d,%d,%d: %s"):format(where, x, y, z, tostring(why)), 0)
end

-- one move; digs/attacks through anything in the way (gravel, mobs, ...)
local function move(go, detect, dig, attack, where)
  local fails = 0
  while not go() do
    if detect() then
      local ok, why = dig()
      if ok then dug = dug + 1
      else
        fails = fails + 1
        if fails > 5 then stuck(where, why) end
        sleep(0.2)
      end
    else
      attack()
      sleep(0.1)
    end
  end
end

local function fwd()
  move(turtle.forward, turtle.detect, turtle.dig, turtle.attack, "forward")
  if f == 0 then x = x + 1 elseif f == 1 then z = z + 1
  elseif f == 2 then x = x - 1 else z = z - 1 end
end
local function up()
  move(turtle.up, turtle.detectUp, turtle.digUp, turtle.attackUp, "up")
  y = y + 1
end
local function down()
  move(turtle.down, turtle.detectDown, turtle.digDown, turtle.attackDown, "down")
  y = y - 1
end

-- keep digging while something is there (falling sand/gravel columns)
local function clearAbove()
  local fails = 0
  while turtle.detectUp() do
    if turtle.digUp() then dug = dug + 1 else
      fails = fails + 1
      if fails > 5 then return end
    end
    sleep(0.05)
  end
end
local function clearBelow()
  local fails = 0
  while turtle.detectDown() do
    if turtle.digDown() then dug = dug + 1 else
      fails = fails + 1
      if fails > 5 then return end
    end
    sleep(0.05)
  end
end

-- horizontal first, then vertical, unless we're climbing (so trips home run
-- along the already-cleared level and drop down the start column)
local function goTo(tx, ty, tz)
  while y < ty do up() end
  if x < tx then face(0) while x < tx do fwd() end end
  if x > tx then face(2) while x > tx do fwd() end end
  if z < tz then face(1) while z < tz do fwd() end end
  if z > tz then face(3) while z > tz do fwd() end end
  while y > ty do down() end
end

local function emptySlots()
  local n = 0
  for s = 1, 16 do if turtle.getItemCount(s) == 0 then n = n + 1 end end
  return n
end

local function isFiller(s)
  local d = turtle.getItemDetail(s)
  return d ~= nil and FILLER[d.name] == true
end

local function fillerCount()
  local n = 0
  for s = 1, 16 do if isFiller(s) then n = n + turtle.getItemCount(s) end end
  return n
end

-- burn anything burnable that isn't filler until we have `need` fuel
local function tryRefuel(need)
  for s = 1, 16 do
    if fuel() >= need then break end
    if turtle.getItemCount(s) > 0 and not isFiller(s) then
      turtle.select(s)
      turtle.refuel()
    end
  end
  turtle.select(1)
  return fuel() >= need
end

local function chestInFront()
  if peripheral.hasType and peripheral.hasType("front", "inventory") then return true end
  local ok, d = turtle.inspect()
  if not ok then return false end
  return d.name:find("chest") ~= nil or d.name:find("barrel") ~= nil
      or d.name:find("shulker") ~= nil
end

-- at home: face the chest behind the start and dump everything but some filler
local function unload()
  face(2)
  if not chestInFront() then
    print("No chest behind my start spot.")
    print("Empty my inventory, then press any key.")
    os.pullEvent("key")
    face(0)
    return
  end
  local kept = 0
  for s = 1, 16 do
    if turtle.getItemCount(s) > 0 then
      local keep = false
      if FILL and isFiller(s) and kept < KEEP_FILLER then
        keep = true
        kept = kept + turtle.getItemCount(s)
      end
      if not keep then
        turtle.select(s)
        if fuel() < 5000 then turtle.refuel() end   -- coal ore drops etc.
        if turtle.getItemCount(s) > 0 and not turtle.drop() then
          print("Chest is full! Empty it, then press any key.")
          os.pullEvent("key")
          turtle.drop()
        end
      end
    end
  end
  turtle.select(1)
  face(0)
end

local function homeDist() return math.abs(x) + math.abs(y) + math.abs(z) end

-- trip home to unload and/or refuel, then back to exactly where we were
local function service()
  local sx, sy, sz, sf = x, y, z, f
  print("Going home to unload/refuel...")
  goTo(0, 0, 0)
  unload()
  local need = 2 * (math.abs(sx) + math.abs(sy) + math.abs(sz)) + L * W + 50
  while fuel() < need do
    if not tryRefuel(need) then
      print(("Need %d fuel, have %d."):format(need, fuel()))
      print("Put fuel in my inventory, then press any key.")
      os.pullEvent("key")
    end
  end
  print("Back to work.")
  goTo(sx, sy, sz)
  face(sf)
end

local function checkup()
  if emptySlots() < 2 then service() return end
  if fuel() < homeDist() + 2 * MAX_FILL_DEPTH + 10 then
    if not tryRefuel(homeDist() + L * W + 50) then service() end
  end
end

-- climb down into a hole under us and fill it back up from the bottom
local function fillHole()
  if turtle.detectDown() then return end
  local have = fillerCount()
  if have == 0 then return end
  local depth = 0
  while depth < MAX_FILL_DEPTH and depth + 1 < have and not turtle.detectDown() do
    down()
    depth = depth + 1
  end
  local function placeOne()
    if turtle.detectDown() then return end
    for s = 1, 16 do
      if isFiller(s) then
        turtle.select(s)
        if turtle.placeDown() then placed = placed + 1 break end
      end
    end
    turtle.select(1)
  end
  placeOne()
  while depth > 0 do
    up()
    depth = depth - 1
    placeOne()
  end
end

-- one layer pass: the turtle sweeps at level `lvl`, optionally clearing the
-- block above/below each cell (3 levels per pass) or filling the floor
local function sweep(lvl, doUp, doDown, doFill)
  checkup()
  goTo(x, lvl, z)
  local zs, cz = 1, 0
  if z ~= 0 then zs, cz = -1, W - 1 end
  local xdir = 1
  if x ~= 0 then xdir = -1 end
  for _ = 1, W do
    local xa, xb = 0, L - 1
    if xdir == -1 then xa, xb = L - 1, 0 end
    for cx = xa, xb, xdir do
      checkup()
      goTo(cx, lvl, cz)
      if doUp then clearAbove() end
      if doDown then clearBelow() end
      if doFill then fillHole() end
    end
    xdir = -xdir
    cz = cz + zs
  end
end

-- ======================================================================

local passes = 1
if H > 2 then passes = 1 + math.ceil((H - 2) / 3) end
if AUTO then
  print(("Flattening %dx%d, height: auto"):format(L, W))
else
  print(("Flattening %dx%d, %d high (%d passes)"):format(L, W, H, passes))
  print(("Rough fuel needed: %d (have %s)"):format(
    passes * L * W + L + W + H, tostring(turtle.getFuelLevel())))
end
if fuel() < L + W + 20 then tryRefuel(L * W + 100) end
if fuel() < 20 then print("I have no fuel. Give me coal and try again.") return end
print("Ctrl+T to stop.")

local ok, err = pcall(function()
  -- pass 1: own level, clear one above, patch holes in the floor
  local before = dug
  sweep(0, H >= 2, false, FILL)
  print(("Layer 1-%d done (%d blocks)"):format(math.min(H, 2), dug - before))
  -- later passes: 3 levels each, turtle in the middle one
  -- auto stops after two empty passes in a row, so a block left floating
  -- above a gap (dug-out sand, tree canopy) still gets found
  local b, empty = 2, 0
  while b < H do
    local top = math.min(b + 2, H - 1)
    local count = top - b + 1
    before = dug
    if count >= 2 then sweep(b + 1, count == 3, true, false)
    else sweep(b, false, false, false) end
    local got = dug - before
    print(("Layer %d-%d done (%d blocks)"):format(b + 1, top + 1, got))
    if got == 0 then empty = empty + 1 else empty = 0 end
    if AUTO and empty >= 2 then break end
    b = b + 3
  end
  -- digging the upper levels drops any sand/gravel resting on them straight
  -- down through the cleared space, so sweep the floor level again
  if b > 2 then
    for _ = 1, 3 do
      before = dug
      sweep(0, H >= 2, false, FILL)
      if dug == before then break end
      print(("Swept up %d fallen blocks"):format(dug - before))
    end
  end
end)

if not ok then print("Stopped: " .. tostring(err)) end
print("Heading home...")
local homeOk, homeErr = pcall(function()
  goTo(0, 0, 0)
  unload()
end)
if not homeOk then print("Couldn't get home: " .. tostring(homeErr)) end
face(0)
print(("Done. Dug %d blocks, filled %d holes."):format(dug, placed))
