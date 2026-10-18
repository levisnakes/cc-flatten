-- Flatten: a mining turtle clears an area down to its own level and patches
-- holes in the floor with the stone/dirt it mined.
--
-- Install it as startup.lua. With no job saved it asks what to flatten;
-- with a job saved (after a deload, server restart or reboot) it picks up
-- exactly where it stopped.
--
--   startup                         ask the questions, then go
--   startup <length> <width> [height|auto] [left] [nofill] [skip]
--   startup cancel                  forget the saved job
--
-- Stand the turtle ON the floor you want (it clears its own level and up),
-- at one corner, facing along the length. The area goes forward <length>
-- and to the right <width> ("left" = to the left). Chest BEHIND it.
-- Ctrl+T pauses; reboot (or run startup) to carry on.
--
-- Surviving a deload: the job and the turtle's position are saved to
-- /flatten.job, and every move is written down before it happens. After a
-- reload the fuel level says whether that last move went through (a move
-- costs exactly 1 fuel). A turn costs no fuel, so if it was unloaded
-- mid-turn it asks you which way it's facing.

VERSION = "2.0.1"

-- ======================== SETTINGS ===========================
-- To keep your own values across updates, put them in /config.lua
-- (same lines, e.g.  MAX_FILL_DEPTH = 10 ).

MAX_FILL_DEPTH = 6      -- how deep a hole it will climb into and fill
KEEP_FILLER = 128       -- cobble/dirt it keeps when unloading, for holes
RESUME_DELAY = 5        -- seconds to press C (cancel) before it resumes

AUTO_UPDATE = true

-- ===================== END OF SETTINGS =======================

if fs and fs.exists("/config.lua") then
  local cf, err = loadfile("/config.lua", nil, _ENV)
  if not cf then error("/config.lua: " .. err, 0) end
  cf()
end

if not turtle then print("This has to run on a turtle.") return end

local args = { ... }
local JOB_FILE = "/flatten.job"

local FILLER = {
  ["minecraft:cobblestone"] = true, ["minecraft:cobbled_deepslate"] = true,
  ["minecraft:dirt"] = true, ["minecraft:coarse_dirt"] = true,
  ["minecraft:stone"] = true, ["minecraft:deepslate"] = true,
  ["minecraft:andesite"] = true, ["minecraft:diorite"] = true,
  ["minecraft:granite"] = true, ["minecraft:tuff"] = true,
  ["minecraft:netherrack"] = true, ["minecraft:sandstone"] = true,
  ["minecraft:calcite"] = true, ["minecraft:blackstone"] = true,
}

-- fuel you gave it stays in the turtle when it unloads (logs etc. don't)
local KEEP_FUEL = {
  ["minecraft:coal"] = true, ["minecraft:charcoal"] = true,
  ["minecraft:coal_block"] = true,
}

-- the job: settings, progress and pose; everything needed to resume
local job
local L, W, H, AUTO, MIRROR, FILL, SKIP

-- position relative to start: x = forward, z = toward the width side, y = up
-- facing: 0 = +x, 1 = +z, 2 = -x, 3 = -z
local x, y, z, f = 0, 0, 0, 0
local dug, placed = 0, 0
local DX = { [0] = 1, 0, -1, 0 }
local DZ = { [0] = 0, 1, 0, -1 }

-- ============================================================ save file

-- written to a .tmp first, so a deload mid-write never leaves a broken file
local function saveJob()
  job.x, job.y, job.z, job.f, job.dug, job.placed = x, y, z, f, dug, placed
  local tmp = JOB_FILE .. ".tmp"
  local h = fs.open(tmp, "w")
  h.write(textutils.serialize(job))
  h.close()
  if fs.exists(JOB_FILE) then fs.delete(JOB_FILE) end
  fs.move(tmp, JOB_FILE)
end

local function loadJob()
  for _, p in ipairs({ JOB_FILE, JOB_FILE .. ".tmp" }) do
    if fs.exists(p) then
      local h = fs.open(p, "r")
      local t = textutils.unserialize(h.readAll())
      h.close()
      if type(t) == "table" and t.L then return t end
    end
  end
  return nil
end

local function clearJob()
  for _, p in ipairs({ JOB_FILE, JOB_FILE .. ".tmp" }) do
    if fs.exists(p) then fs.delete(p) end
  end
end

-- ============================================================ prompts

local function ask(q)
  write(q .. " ")
  return read()
end

local function askYN(q)
  while true do
    local a = ask(q .. " (y/n)"):lower():sub(1, 1)
    if a == "y" then return true end
    if a == "n" then return false end
  end
end

local function askNums(q, n)
  while true do
    local nums = {}
    for v in ask(q):gmatch("-?%d+") do nums[#nums + 1] = tonumber(v) end
    if #nums == n then return table.unpack(nums) end
    print(n == 1 and "Type a number." or ("Type " .. n .. " numbers, like: 120 64 -45"))
  end
end

local FACE = { n = { 0, -1 }, s = { 0, 1 }, e = { 1, 0 }, w = { -1, 0 } }

local function askDir(q)
  while true do
    local v = FACE[ask(q .. " (n/s/e/w)"):lower():sub(1, 1)]
    if v then return v end
  end
end

-- world <-> turtle-local; job.fv = world direction of local +x, job.sv = +z
local function toLocal(wx, wz)
  local dx, dz = wx - job.wx, wz - job.wz
  return dx * job.fv[1] + dz * job.fv[2], dx * job.sv[1] + dz * job.sv[2]
end

local function localFacing(v)
  for d = 0, 3 do
    local lx, lz = DX[d], DZ[d]
    local wx = lx * job.fv[1] + lz * job.sv[1]
    local wz = lx * job.fv[2] + lz * job.sv[2]
    if wx == v[1] and wz == v[2] then return d end
  end
end

local function gpsXYZ()
  if not (gps and gps.locate) then return nil end
  local gx, gy, gz = gps.locate(2)
  if not gx then return nil end
  return math.floor(gx), math.floor(gy + 0.5), math.floor(gz)
end

-- ============================================================ skip zones
-- columns it never enters or digs, at any level (your base)

local function skipped(cx, cz)
  for _, r in ipairs(SKIP) do
    if cx >= r[1] and cx <= r[3] and cz >= r[2] and cz <= r[4] then return true end
  end
  return false
end

local function open(cx, cz)
  return cx >= 0 and cx < L and cz >= 0 and cz < W and not skipped(cx, cz)
end

local NEIGHBORS = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }

-- breadth-first search from (fx0, fz0); returns the predecessor map
local function bfs(fx0, fz0, tx, tz)
  local function key(cx, cz) return cz * L + cx end
  local prev, q, head = { [key(fx0, fz0)] = false }, { { fx0, fz0 } }, 1
  while head <= #q do
    local c = q[head]
    head = head + 1
    if c[1] == tx and c[2] == tz then break end
    for _, d in ipairs(NEIGHBORS) do
      local nx, nz = c[1] + d[1], c[2] + d[2]
      if open(nx, nz) and prev[key(nx, nz)] == nil then
        prev[key(nx, nz)] = c
        q[#q + 1] = { nx, nz }
      end
    end
  end
  return prev, #q, key
end

-- ============================================================ movement

local function fuel()
  local l = turtle.getFuelLevel()
  if l == "unlimited" then return math.huge end
  return l
end

-- every move and turn is written down first ("pend"), then cleared
local function journal(kind, to)
  job.pend = { kind = kind, fuel = turtle.getFuelLevel(), f = f, to = to }
  saveJob()
end
local function settled()
  job.pend = nil
  saveJob()
end

local function right()
  journal("turn", (f + 1) % 4)
  if MIRROR then turtle.turnLeft() else turtle.turnRight() end
  f = (f + 1) % 4
  settled()
end
local function left()
  journal("turn", (f + 3) % 4)
  if MIRROR then turtle.turnRight() else turtle.turnLeft() end
  f = (f + 3) % 4
  settled()
end
local function face(d)
  if (d - f) % 4 == 3 then left() else while f ~= d do right() end end
end

local function stuck(where, why)
  error(("Can't dig %s at %d,%d,%d: %s"):format(where, x, y, z, tostring(why)), 0)
end

-- one move; digs/attacks through anything in the way (gravel, mobs, ...).
-- Every turtle call costs game ticks, so it tries the likely thing first:
-- dig-then-move when the last forward step was through solid ground,
-- move-then-dig when it was through air. Only checks detect() on a failure.
local function move(go, detect, dig, attack, where, digFirst)
  local hit = false
  if digFirst and dig() then dug = dug + 1 hit = true end
  local fails = 0
  while not go() do
    local ok, why = dig()
    if ok then dug = dug + 1 hit = true
    elseif detect() then
      fails = fails + 1
      if fails > 5 then stuck(where, why) end
      sleep(0.2)
    else
      attack()
    end
  end
  return hit
end

local solidAhead = false
local function fwd()
  journal("fwd")
  solidAhead = move(turtle.forward, turtle.detect, turtle.dig, turtle.attack, "forward", solidAhead)
  x, z = x + DX[f], z + DZ[f]
  settled()
end
local function up()
  journal("up")
  move(turtle.up, turtle.detectUp, turtle.digUp, turtle.attackUp, "up")
  y = y + 1
  settled()
end
local function down()
  journal("down")
  move(turtle.down, turtle.detectDown, turtle.digDown, turtle.attackDown, "down")
  y = y - 1
  settled()
end

-- dig until there's nothing left (sand/gravel columns drop into the gap).
-- dig on air just returns false, so no detect() call is needed first.
-- Gravel that lands a few ticks later gets caught by the final floor sweep.
local function clearAbove()
  while turtle.digUp() do dug = dug + 1 end
end
local function clearBelow()
  while turtle.digDown() do dug = dug + 1 end
end

-- is the straight L-shaped path (x leg first, or z leg first) clear?
local function legClear(ax, az, bx, bz, xFirst)
  local sx = (bx > ax) and 1 or -1
  local sz = (bz > az) and 1 or -1
  if xFirst then
    for cx = ax, bx, sx do if not open(cx, az) then return false end end
    for cz = az, bz, sz do if not open(bx, cz) then return false end end
  else
    for cz = az, bz, sz do if not open(ax, cz) then return false end end
    for cx = ax, bx, sx do if not open(cx, bz) then return false end end
  end
  return true
end

local function walkTo(tx, tz)
  if x == tx and z == tz then return end
  local function legs(xFirst)
    if xFirst then
      if x < tx then face(0) while x < tx do fwd() end end
      if x > tx then face(2) while x > tx do fwd() end end
    end
    if z < tz then face(1) while z < tz do fwd() end end
    if z > tz then face(3) while z > tz do fwd() end end
    if x < tx then face(0) while x < tx do fwd() end end
    if x > tx then face(2) while x > tx do fwd() end end
  end
  if #SKIP == 0 or legClear(x, z, tx, tz, true) then legs(true) return end
  if legClear(x, z, tx, tz, false) then legs(false) return end
  local prev, _, key = bfs(x, z, tx, tz)
  if prev[key(tx, tz)] == nil then
    error(("No way around the skip zone to %d,%d"):format(tx, tz), 0)
  end
  local path, c = {}, { tx, tz }
  while c do table.insert(path, 1, c) c = prev[key(c[1], c[2])] end
  for i = 2, #path do
    local nx, nz = path[i][1], path[i][2]
    if nx > x then face(0) elseif nx < x then face(2)
    elseif nz > z then face(1) else face(3) end
    fwd()
  end
end

-- climb first, walk, then drop (so trips home run along the cleared level
-- and come down the start column)
local function goTo(tx, ty, tz)
  while y < ty do up() end
  walkTo(tx, tz)
  while y > ty do down() end
end

-- ============================================================ inventory

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
      local d = turtle.getItemDetail(s)
      local keep = d ~= nil and KEEP_FUEL[d.name] == true
      if not keep and FILL and isFiller(s) and kept < KEEP_FILLER then
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

-- trip home to unload and/or refuel, then back to exactly where we were.
-- (A deload mid-trip is fine: on resume it just heads for its cell again.)
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

-- ============================================================ the job

-- auto-update waits for a spot between cells (the job is saved there)
local wantUpdate, safeNow = false, false
local function safePoint()
  if not wantUpdate then return end
  safeNow = true
  print("Updating; I'll carry on from here after.")
  sleep(60)
  safeNow, wantUpdate = false, false
end

-- cell i of a sweep, snaking row by row from the sweep's start corner
local function cellAt(sw, i)
  local r = math.floor((i - 1) / L)
  local k = (i - 1) % L
  local cz = sw.cz0 + r * sw.zs
  if (r % 2 == 0) == (sw.xdir0 == 1) then return k, cz end
  return L - 1 - k, cz
end

-- one layer pass at level `lvl`, optionally clearing the block above/below
-- each cell (3 levels per pass) or filling the floor. Saved after each cell.
local function runSweep(lvl, doUp, doDown, doFill)
  local sw = job.sw
  if not sw then
    sw = { i = 1, startDug = dug, zs = 1, cz0 = 0, xdir0 = 1 }
    if z ~= 0 then sw.zs, sw.cz0 = -1, W - 1 end   -- start from the near corner
    if x ~= 0 then sw.xdir0 = -1 end
    job.sw = sw
    saveJob()
  end
  while sw.i <= L * W do
    local cx, cz = cellAt(sw, sw.i)
    if not skipped(cx, cz) then
      checkup()
      goTo(cx, lvl, cz)
      if doUp then clearAbove() end
      if doDown then clearBelow() end
      if doFill then fillHole() end
    end
    sw.i = sw.i + 1
    saveJob()
    safePoint()
  end
  local got = dug - sw.startDug
  job.sw = nil
  saveJob()
  return got
end

local function runJob()
  while true do
    local ph = job.phase
    if ph == "p1" then
      -- pass 1: own level, clear one above, patch holes in the floor
      local got = runSweep(0, H >= 2, false, FILL)
      print(("Layer 1-%d done (%d blocks)"):format(math.min(H, 2), got))
      job.phase = "upper"
      saveJob()
    elseif ph == "upper" then
      -- 3 levels per pass, turtle in the middle one. Auto stops after two
      -- empty passes in a row, so a block left floating above a gap
      -- (dug-out sand, tree canopy) still gets found.
      local b = job.b
      if b >= H then
        job.phase = "final"
      else
        local top = math.min(b + 2, H - 1)
        local count = top - b + 1
        local got
        if count >= 2 then got = runSweep(b + 1, count == 3, true, false)
        else got = runSweep(b, false, false, false) end
        print(("Layer %d-%d done (%d blocks)"):format(b + 1, top + 1, got))
        job.upperRan = true
        if got == 0 then job.empty = job.empty + 1 else job.empty = 0 end
        if AUTO and job.empty >= 2 then job.phase = "final" else job.b = b + 3 end
      end
      saveJob()
    elseif ph == "final" then
      -- digging the upper levels drops any sand/gravel resting on them
      -- straight down through the cleared space, so sweep the floor again
      if not job.upperRan or job.round >= 3 then
        job.phase = "home"
      else
        local got = runSweep(0, H >= 2, false, FILL)
        job.round = job.round + 1
        if got == 0 then job.phase = "home"
        else print(("Swept up %d fallen blocks"):format(got)) end
      end
      saveJob()
    else
      print("Heading home...")
      goTo(0, 0, 0)
      unload()
      face(0)
      clearJob()
      print(("Done. Dug %d blocks, filled %d holes."):format(dug, placed))
      return
    end
  end
end

-- ============================================================ resume

-- settle a move/turn that was in progress when the turtle got unloaded
local function resolvePending()
  local p = job.pend
  if not p then return end
  if p.kind == "turn" then
    print("I got unloaded in the middle of a turn.")
    local d
    repeat
      d = localFacing(askDir("Which way is my front facing?"))
      if d == nil then print("That doesn't match my area, try again.") end
    until d ~= nil
    f = d
  else
    local fl = turtle.getFuelLevel()
    local moved
    if fl ~= "unlimited" and fl == p.fuel - 1 then moved = true
    elseif fl ~= "unlimited" and fl == p.fuel then moved = false end
    if moved == true then
      if p.kind == "fwd" then x, z = x + DX[p.f], z + DZ[p.f]
      elseif p.kind == "up" then y = y + 1
      else y = y - 1 end
    elseif moved == nil then
      -- unlimited fuel or someone refuelled it: need the real position
      print("I got unloaded mid-move and can't tell if it finished.")
      local wx, wy, wz = gpsXYZ()
      if not wx then wx, wy, wz = askNums("Type MY X Y Z (look at me with F3):", 3) end
      x, z = toLocal(wx, wz)
      y = wy - job.wy
    end
  end
  job.pend = nil
  saveJob()
end

-- ============================================================ new job setup

local function connected()
  if skipped(0, 0) then return false, "The turtle's own spot is inside a skip zone!" end
  local total = 0
  for cx = 0, L - 1 do for cz = 0, W - 1 do if open(cx, cz) then total = total + 1 end end end
  local _, reached = bfs(0, 0, -1, -1)
  if reached < total then
    return false, "A skip zone cuts the area in two, so I can't reach part of it. Run each side separately."
  end
  return true
end

local function newJob()
  local cfg = { H = 256, AUTO = true, MIRROR = false, FILL = true }
  local wantSkip = false
  if #args >= 2 then
    cfg.L, cfg.W = tonumber(args[1]), tonumber(args[2])
    for i = 3, #args do
      local a = args[i]:lower()
      if tonumber(a) then cfg.H, cfg.AUTO = tonumber(a), false
      elseif a == "left" then cfg.MIRROR = true
      elseif a == "nofill" then cfg.FILL = false
      elseif a == "skip" then wantSkip = true
      elseif a ~= "auto" then cfg.L = nil end
    end
    if not cfg.L or not cfg.W or cfg.L < 1 or cfg.W < 1 or cfg.H < 1 then
      print("Usage: startup <length> <width> [height|auto]")
      print("       [left] [nofill] [skip]")
      print("   or just: startup   (it asks)")
      return nil
    end
  else
    print("Flatten setup. Stand me ON the floor level you want,")
    print("in a corner, facing along the length, chest behind me.")
    cfg.L = askNums("Length (forward from me):", 1)
    cfg.W = askNums("Width (to the side):", 1)
    while true do
      local a = ask("Height in blocks, counting my level (or auto):"):lower()
      if a == "auto" then break end
      if tonumber(a) and tonumber(a) >= 1 then cfg.H, cfg.AUTO = tonumber(a), false break end
    end
    cfg.MIRROR = ask("Width goes to my right or left? (r/l)"):lower():sub(1, 1) == "l"
    cfg.FILL = askYN("Fill holes in the floor?")
    wantSkip = askYN("Any area it must not dig (your base)?")
  end
  cfg.L, cfg.W, cfg.H = math.floor(cfg.L), math.floor(cfg.W), math.floor(cfg.H)

  -- where it is in the world: for skip zones and for sorting out a deload
  local wx, wy, wz = gpsXYZ()
  if wx then print(("GPS: I'm at %d %d %d"):format(wx, wy, wz))
  else wx, wy, wz = askNums("My X Y Z (F3, standing in my spot):", 3) end
  local fv = askDir("Which way do I face?")
  local sv = { -fv[2], fv[1] }               -- to my right
  if cfg.MIRROR then sv = { -sv[1], -sv[2] } end

  job = {
    L = cfg.L, W = cfg.W, H = cfg.H, AUTO = cfg.AUTO, MIRROR = cfg.MIRROR, FILL = cfg.FILL,
    SKIP = {}, wx = wx, wy = wy, wz = wz, fv = fv, sv = sv,
    phase = "p1", b = 2, empty = 0, round = 0, upperRan = false,
  }
  L, W, H, AUTO, MIRROR, FILL, SKIP = job.L, job.W, job.H, job.AUTO, job.MIRROR, job.FILL, job.SKIP

  if wantSkip then
    repeat
      print("Skip zone " .. (#SKIP + 1) .. " (it won't dig these columns):")
      local ax, az = toLocal(askNums(" Corner 1 X Z:", 2))
      local bx, bz = toLocal(askNums(" Opposite corner X Z:", 2))
      local r = { math.min(ax, bx), math.min(az, bz), math.max(ax, bx), math.max(az, bz) }
      if r[3] < 0 or r[1] >= L or r[4] < 0 or r[2] >= W then
        print(" That zone is outside the area, ignoring it.")
      else
        SKIP[#SKIP + 1] = r
        print((" OK: %d-%d forward, %d-%d to the side"):format(r[1], r[3], r[2], r[4]))
      end
    until not askYN("Add another skip zone?")
    local ok, why = connected()
    if not ok then print(why) return nil end
  end

  local passes = 1
  if H > 2 then passes = 1 + math.ceil((H - 2) / 3) end
  if AUTO then
    print(("Flattening %dx%d, height: auto"):format(L, W))
  else
    print(("Flattening %dx%d, %d high (%d passes)"):format(L, W, H, passes))
    print(("Rough fuel needed: %d (have %s)"):format(
      passes * L * W + L + W + H, tostring(turtle.getFuelLevel())))
  end
  if not askYN("Start?") then return nil end
  return job
end

-- ============================================================ auto-update

-- Every UPDATE_CHECK_MINUTES this checks GitHub for a newer version. A new
-- version is downloaded, checked that it loads, given your current settings
-- (the UPPERCASE lines at the top of this file), saved, and the computer
-- reboots into it. Set AUTO_UPDATE = false at the top to turn this off.
-- The job file survives the reboot, so it carries on where it was.
local readyToUpdate, checkForUpdate, updateLoop, bootUpdate
do
local UPDATE_REPO = "levisnakes/cc-flatten"
local UPDATE_FILE = "flatten.lua"
local UPDATE_CHECK_MINUTES = 15
local PROGRAM_PATH = (shell and shell.getRunningProgram()) or "startup.lua"
local SHA_FILE = "/.version_" .. UPDATE_FILE

-- only between cells, where the job was just saved
readyToUpdate = function()
  wantUpdate = true
  return safeNow
end

-- Settings are the top-of-file assignments to UPPERCASE names, before the
-- first "local" line or "-- ====" section. Tables can span several lines.
local function splitSettings(src)
  local settings, rest = {}, {}
  local inSettings = true
  for line in (src .. "\n"):gmatch("(.-)\n") do
    if inSettings and (line:match("^local ") or line:match("^%-%- ====")) then inSettings = false end
    table.insert(inSettings and settings or rest, line)
  end
  return settings, rest
end

local function braceDelta(line)
  local code = line:gsub('"[^"]*"', ""):gsub("%-%-.*$", "")
  local _, opens = code:gsub("{", "")
  local _, closes = code:gsub("}", "")
  return opens - closes
end

-- [NAME] = the full statement text, possibly several lines
local function statements(lines)
  local out = {}
  local i = 1
  while i <= #lines do
    local name = lines[i]:match("^([%u_][%u%d_]*)%s*=")
    if name then
      local block = { lines[i] }
      local depth = braceDelta(lines[i])
      while depth > 0 and i < #lines do
        i = i + 1
        table.insert(block, lines[i])
        depth = depth + braceDelta(lines[i])
      end
      out[name] = table.concat(block, "\n")
    end
    i = i + 1
  end
  return out
end

-- New file, with each setting that already exists replaced by your value.
local function mergeSettings(oldSrc, newSrc)
  local oldSettings = statements((splitSettings(oldSrc)))
  local newSettings, rest = splitSettings(newSrc)
  local out = {}
  local i = 1
  while i <= #newSettings do
    local line = newSettings[i]
    local name = line:match("^([%u_][%u%d_]*)%s*=")
    if name and oldSettings[name] then
      table.insert(out, oldSettings[name])
      local depth = braceDelta(line)
      while depth > 0 and i < #newSettings do
        i = i + 1
        depth = depth + braceDelta(newSettings[i])
      end
    else
      table.insert(out, line)
    end
    i = i + 1
  end
  for _, line in ipairs(rest) do table.insert(out, line) end
  local merged = table.concat(out, "\n")
  -- splitting added one trailing newline's worth of empty line; match the source
  if newSrc:sub(-1) == "\n" and merged:sub(-1) ~= "\n" then merged = merged .. "\n" end
  return (merged:gsub("\n\n$", "\n"))
end

local function fetch(url, headers)
  local ok, h = pcall(http.get, url, headers)
  if not ok or not h then return nil end
  local body = h.readAll()
  h.close()
  return body
end

local function readText(path)
  if not fs.exists(path) then return nil end
  local fh = fs.open(path, "r")
  local t = fh.readAll()
  fh.close()
  return t
end

local function writeText(path, text)
  local fh = fs.open(path, "w")
  fh.write(text)
  fh.close()
end

checkForUpdate = function(atBoot)
  if AUTO_UPDATE == false or not http then return end
  local sha = fetch("https://api.github.com/repos/" .. UPDATE_REPO .. "/commits/main",
    { ["Accept"] = "application/vnd.github.sha", ["User-Agent"] = "cc-auto-update" })
  if not sha then return end
  sha = sha:match("^%s*(%x+)%s*$")
  if not sha or #sha < 40 or readText(SHA_FILE) == sha then return end

  local newSrc = fetch("https://raw.githubusercontent.com/" .. UPDATE_REPO .. "/" .. sha .. "/" .. UPDATE_FILE)
  if not newSrc or not load(newSrc, UPDATE_FILE) then return end
  local oldSrc = readText(PROGRAM_PATH)
  if not oldSrc then return end
  local merged = mergeSettings(oldSrc, newSrc)
  if not load(merged, UPDATE_FILE) then return end
  if merged == oldSrc then
    writeText(SHA_FILE, sha)
    return
  end

  -- at boot nothing is running yet, so there is nothing to wait for
  while not atBoot and not readyToUpdate() do sleep(5) end
  writeText(PROGRAM_PATH .. ".old", oldSrc)
  writeText(PROGRAM_PATH, merged)
  writeText(SHA_FILE, sha)
  term.setBackgroundColor(colors.black)
  term.clear()
  term.setCursorPos(1, 1)
  print("Updated to " .. sha:sub(1, 7) .. ", restarting...")
  if not atBoot then sleep(1) end
  os.reboot()
end

updateLoop = function()
  while true do
    sleep(UPDATE_CHECK_MINUTES * 60)
    pcall(checkForUpdate)
  end
end

-- Check for a new version as soon as the computer starts, before the
-- program runs, so a restart always picks up the latest version.
bootUpdate = function()
  if AUTO_UPDATE == false or not http then return end
  term.setBackgroundColor(colors.black)
  term.clear()
  term.setCursorPos(1, 1)
  print("Checking for updates...")
  pcall(checkForUpdate, true)
end
end

-- ============================================================ main

if args[1] == "cancel" then
  clearJob()
  print("Saved job deleted.")
  return
end

bootUpdate()

job = loadJob()
if job and #args > 0 then
  print("There's a saved job. Run 'startup cancel' first")
  print("to start a new one, or just 'startup' to resume it.")
  return
end

if job then
  L, W, H, AUTO, MIRROR, FILL, SKIP = job.L, job.W, job.H, job.AUTO, job.MIRROR, job.FILL, job.SKIP
  x, y, z, f, dug, placed = job.x, job.y, job.z, job.f, job.dug or 0, job.placed or 0
  print(("Flatten job %dx%d: resuming in %ds."):format(L, W, RESUME_DELAY))
  print("Press C to cancel the job, any other key to go now.")
  local timer = os.startTimer(RESUME_DELAY)
  while true do
    local ev, p1 = os.pullEvent()
    if ev == "timer" and p1 == timer then break end
    if ev == "char" then
      if p1:lower() == "c" then
        if askYN("Delete the saved job?") then clearJob() print("Job deleted.") return end
      end
      break
    end
  end
  resolvePending()
else
  if not newJob() then return end
  if fuel() < L + W + 20 then tryRefuel(L * W + 100) end
  if fuel() < 20 then print("I have no fuel; I'll ask for some.") end
  saveJob()
end

print("Ctrl+T pauses (reboot to carry on).")
local ok, err
parallel.waitForAny(function()
  ok, err = pcall(runJob)
end, updateLoop)

if not ok then
  if err == "Terminated" then
    print("Paused. Reboot or run startup to carry on;")
  else
    print("Stopped: " .. tostring(err))
    print("Fix that, then reboot to carry on;")
  end
  print("'startup cancel' drops the job.")
end
