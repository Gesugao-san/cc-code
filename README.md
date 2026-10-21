<p align="center">
	<h2 align="center">cc-code</h2>
	<p align="center">
		Lua programs for
		<a href="https://tweaked.cc/">CC: Tweaked</a>
		(ComputerCraft) computers and turtles.
	</p>
</p>

<p align="center">
	<a href="https://code.visualstudio.com/">
		<img alt="[Made in VS Code]"
		src="./.github/static/Made_in-VS_Code-1f425f.svg"/>
	</a>˙
	<a href="https://opensource.org/licenses/MIT">
		<img alt="[License MIT]"
		src="./.github/static/License-MIT-yellow.svg"/>
	</a>˙
	<a href="./../../commits/">
		<img alt="[Last Commit]"
		src="https://img.shields.io/github/last-commit/Gesugao-san/cc-code"/>
	</a>
</p>

---

## Table of Contents

- [Table of Contents](#table-of-contents)
- [Programs](#programs)
- [Installing](#installing)
- [For contributors](#for-contributors)

## Programs

All programs are in [`src/`](./src).

| Program | What it does |
|---|---|
| [`dumpmethods`](./src/dumpmethods.lua) | Saves methods of every attached peripheral (including wired network ones) to a file. Usage: `dumpmethods [output_file]` |
| [`find-modem`](./src/find-modem.lua) | Lists attached modems and shows which are wireless |
| [`gps-fork`](./src/gps-fork.lua) | Fork of the built-in `gps` program: finds wireless modems on the wired network too, optional emulation mode |
| [`gps-host-d`](./src/gps-host-d.lua) | GPS "cell tower" daemon. Usage: `gps-host-d [<x> <y> <z>]` |
| [`rednet-d`](./src/rednet-d.lua) | Rednet daemon that runs commands sent by the master computer |
| [`tank`](./src/tank.lua) | Moves Liquid Experience from a Create Enchantment Industry disenchanter into a fluid tank |
| [`time-print`](./src/time-print.lua) | Shows the in-game time on a Create Display Link |
| [`turtle`](./src/turtle.lua) | Turtle builds a line of pipes and small cogwheels overhead |
| [`unknown-scada-1`](./src/unknown-scada-1.lua) | Create stress monitor with an on/off button (simple layout) |
| [`unknown-scada-2`](./src/unknown-scada-2.lua) | Create stress monitor with a usage bar, overload alert and on/off button |

## Installing

**Drag and drop.** Run `import` on the computer and drag the `.lua` file
into the Minecraft window.

**Download from GitHub** (needs HTTP enabled on the server):

```shell
wget https://github.com/Gesugao-san/cc-code/raw/refs/heads/master/src/dumpmethods.lua dumpmethods.lua
```

Replace `dumpmethods` with the program you need.

## For contributors

 1. [Contributing](./.github/CONTRIBUTING.md)
 1. [ToDo list](./.github/TODO.md)
 1. [Download](./.github/DOWNLOAD.md)

---

<p align="center">
  <img src="https://2ip.io/bar/ip3.gif"/>
</p>
