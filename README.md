# Flatten

ComputerCraft program for a **mining turtle**. It clears a rectangle down to the turtle's own level and fills holes in the floor with the stone and dirt it digs up. It runs as `startup.lua` and **survives deloads and server restarts**: when the chunk loads again it carries on where it stopped.

## Install

```
wget https://raw.githubusercontent.com/levisnakes/cc-flatten/main/flatten.lua startup.lua
```

## Use

1. Stand the turtle **on top of the floor you want**, at one corner of the area. It clears its own level and everything above.
2. Face it along the length. The area runs forward (length) and to the **right** (width), or to the left if you choose that.
3. Put a **chest behind it**. When its inventory fills up it goes back, unloads, and returns to where it stopped. It keeps 2 stacks of cobble/dirt for filling holes.
4. Give it fuel (coal etc.). It also burns any fuel it digs up. If it runs low it comes home and waits for you to add more.
5. Run `startup` (or reboot it) and answer the questions: length, width, height, right/left, fill holes, base to avoid, its X Y Z, and which way it faces.

Or skip the questions: `startup <length> <width> [height|auto] [left] [nofill] [skip]`

- `startup cancel` forgets the saved job.
- Ctrl+T pauses. Reboot or run `startup` to carry on.
- On boot with a saved job it waits 5 seconds. Press **C** to cancel the job, or any other key to start right away.

## Deloads and restarts

The job and the turtle's position are saved to `/flatten.job`. Every move is written down before it happens, and after a reload the fuel level shows whether that last move went through, since a move costs exactly 1 fuel. If it got unloaded in the middle of a **turn** (which costs no fuel), it asks which way it's facing; answer n/s/e/w.

## Protecting your base

Say yes to "Any area it must not dig?" (or add `skip`), then give two opposite corners of the base (F3 X Z). Add more zones if you need them. It won't enter or dig those columns at any height, and it paths around them. If a zone cuts the area in two, it tells you to run each side separately.

## Notes

- Height counts the turtle's own level. Turtle at Y 84, clear through Y 117 → height 34. `auto` keeps going up until two layers in a row are empty.
- It clears 3 levels per pass (dig up, dig down, move), so each pass costs about `length x width` fuel.
- Holes up to 6 deep get filled from the bottom up. Water and lava pools get filled the same way.
- Sand and gravel that fall into the cleared space get swept up in a final pass.
- It auto-updates from this repo. Updates wait for a moment when the job is saved, and it carries on after the reboot. Set `AUTO_UPDATE = false` in `/config.lua` to turn that off.
