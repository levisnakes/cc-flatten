# Flatten

ComputerCraft program for a **mining turtle**. It clears a rectangle down to the turtle's own level and fills holes in the floor with the stone and dirt it digs up.

## Install

```
wget https://raw.githubusercontent.com/levisnakes/cc-flatten/main/flatten.lua flatten.lua
```

## Use

```
flatten <length> <width> [height|auto] [left] [nofill]
```

1. Stand the turtle **on top of the floor you want**, at one corner of the area. It clears its own level and everything above.
2. Face it along the length. The area runs `length` forward and `width` to the **right**. Add `left` to go left instead.
3. Put a **chest behind it**. When its inventory fills up it goes back, unloads, and returns to where it stopped. It keeps 2 stacks of cobble/dirt for filling holes.
4. Give it fuel (coal etc.). It also burns any fuel it digs up. If it runs low it comes home and waits for you to add more.

Examples:

- `flatten 32 32`: 32x32, keeps going up until two layers in a row are empty (auto).
- `flatten 20 10 6`: clears exactly 6 blocks high.
- `flatten 16 16 auto left nofill`: area goes to the left, holes are left alone.

Notes:

- It clears 3 levels per pass (dig up, dig down, move), so each pass costs about `length x width` fuel.
- Holes up to 6 deep get filled from the bottom up. Water and lava pools get filled the same way.
- Sand and gravel that fall into the cleared space get swept up in a final pass.
- Ctrl+T once stops the job and sends the turtle home. Ctrl+T again stops it right where it is.
