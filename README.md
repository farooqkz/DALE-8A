# DALE-8A: A CHIP-8 platform emulator for POSIX AWK

This is an advanced port of my previous JS-based CHIP-8 emulator, [DALE-8](https://gitlab.com/suborg/dale-8/), to the AWK programming language in its standard (POSIX) variation. The port was also inspired by [awk-chip8 by patsie75](https://github.com/patsie75/awk-chip8) although not a single piece of code is used from there as that emulator heavily depends on GAWK-specific features and doesn't emulate certain ROM quirks. Compared to the original DALE-8, DALE-8A drops the sound output capability but implements everything else using CLI pseudographics and also is fully compatible with low-res CHIP-8 ROMs developed using the [Octo](https://johnearnest.github.io/Octo/index.html) IDE. All the required interactive input and binary loading functions are provided by my own POSIX-compatible library, `tgl.awk` (The Great Library). As such, DALE-8A externally depends on the `stty` and `od` commands only.

Since AWK environments can vary in terms of execution speed, DALE-8A performs all necessary profiling before running the main code in order to reduce dependency on external timing utilities like `sleep`. Because this profiling depends on the `$EPOCHREALTIME` environment variable, it's recommended to run DALE-8A from the shell that supports it, like Bash 5.x and above or BusyBox with the corresponding compilation flags. In case this variable is unavailable, a fallback timing method is used which is much less accurate and can make emulation too slow or too fast.

DALE-8A was created more as an excercise to improve the algorithmic part of CHIP-8 emulation and to practice optimizing portable AWK code. Yet, combined with `busybox awk`, it can be practically used in some embedded environments where deploying any other VM is not easy.

## Supported specification

- Screen resolution: 64x32, 8px wide sprites (no extended screen mode support), 60 Hz refresh rate
- Color palette: monochrome (both foreground and background colors are configurable)
- Memory: 4096 bytes
- 16 operation registers: V0 to VF
- Service registers: address register I, delay timer DT and sound timer ST
- 16-digit CHR ROM (loaded at 0x80)
- 3584-byte PRG ROM (loaded at 0x200)
- Subroutine call stack with the depth of 1792 (theoretically covers all loadable memory)
- All standard 35 opcodes support (RCA-specific `0NNN` calls, except `00E0` and `00EE`, are ignored) - see the list below
- Five optional CPU quirks required for some games are implemented - see below
- Sound timer register is supported but has no effect

DALE-8A passes all relevant tests from [Timendus' CHIP-8 test suite 4.0](https://github.com/Timendus/chip8-test-suite), as well as some others, which are included in the `testroms` directory of this repo. It is capable of running everything compiled for the bare CHIP-8 in Octo by default, as well as all old games using the `LSQ` and/or `STQ` quirks.

## Usage

### Running the emulator

The most convenient way of running CHIP-8 ROMs is using the shell wrapper from this package:

```
sh dale8a.sh prog.ch8
```

You can also run the AWK file itself directly as follows:

```
LANG=C awk -f tgl.awk -f dale8a.awk [params] -- prog.ch8
```

If the ROM file has `.l.ch8` extension, additional `LSQ` emulation quirk will be applied (see below). If the file has `.s.ch8` extention, additional `STQ` emulation quirk will be applied (see below). Is the file has `.sl.ch8` or `.ls.ch8` extension, both quirks will be applied.

### Configuration variables

The DALE-8A script allows to pass a number of configuration variables to the engine using the standard `-v` option of AWK:

- `CLOCK_FACTOR` - the number of CPU cycles executed per single frame, default 20
- `PXL_COLOR` - set the main screen foreground color (1 to 7), default 2 (green)
- `BG_COLOR` - set the main screen background color (0 to 7), default 0 (black)
- `SBAR_COLOR`- set the statusbar foreground color (1 to 7), default 3 (yellow)
- `SBAR_BG_COLOR` - set the statusbar background color (0 to 7), default 0 (black)
- `EMU_QUIRK_LSQ` - apply `LSQ` quirk (if set with `-v`, overrides the filename-based setting)
- `EMU_QUIRK_STQ` - apply `STQ` quirk (if set with `-v`, overrides the filename-based setting)
- `EMU_QUIRK_VIP` - apply `VIP` quirk
- `EMU_QUIRK_JMP` - apply `JMP` quirk
- `EMU_QUIRK_CRY` - apply `CRY` quirk

The clock factor variable change can be required by some games that were designed to run under high CPU rate.

The color values from 0 to 7 correspond to the standard ANSI terminal codes: black, red, green, yellow, blue, magenta, cyan and white respectively. For the foreground values, the "bold" text attribute is also applied where supported, so they are brighter than usual.

For the emulation quirks description, see the "Supported opcode list" section below. All the quirk-related variables are unset by default.

### Status bar

Above the virtual screen, a status bar is displayed. It contains the current ROM filename and the quirk emulation status in the following order: `LSQ STQ VIP JMP CRY`. If a quirk is off, it won't appear in this list.

### Controls

- **Exiting**: At any point, press Escape to exit the emulator. If running via the `dale8.sh` wrapper, it's also safe to press Ctrl+C.
- **Keyboard mapping** is the same as the default one in the Octo emulator:

Virtual  |Keyboard
---------|---------
`1 2 3 C`|`1 2 3 4`
`4 5 6 D`|`q w e r`
`7 8 9 E`|`a s d f`
`A 0 B F`|`z x c v`

## Supported opcode list

These are all the opcodes supported by DALE-8A. The list of mnemonics is taken [from here](http://devernay.free.fr/hacks/chip8/C8TECH10.HTM). All arithmetics is unsigned 8-bit (modulo 256). Arithmetics on the `I` register is unsigned 16-bit.

Opcode | Assembly instruction | Meaning | Notes
-------|----------------------|---------|------
00E0 | CLS | Clear the screen |
00EE | RET | Return from the subroutine | Does nothing if we're on the top of call stack
0nnn | SYS addr | Machine ROM call at addr | Isn't used in any modern CHIP-8 programs and ignored by DALE-8A
1nnn | JP addr | Unconditional jump to addr |
2nnn | CALL addr | Call the subroutine at addr |
3xkk | SE Vx, byte | Skip next instruction if Vx == byte |
4xkk | SNE Vx, byte | Skip next instruction if Vx != byte |
5xy0 | SE Vx, Vy | Skip next instruction if Vx == Vy |
6xkk | LD Vx, byte | Set Vx = byte |
7xkk | ADD Vx, byte | Set Vx = Vx + byte |
8xy0 | LD Vx, Vy | Set Vx = Vy |
8xy1 | OR Vx, Vy | Set Vx = Vx OR Vy | Bitwise OR. If `VIP` quirk is **on**, also clear the VF register
8xy2 | AND Vx, Vy | Set Vx = Vx AND Vy | Bitwise AND. If `VIP` quirk is **on**, also clear the VF register
8xy3 | XOR Vx, Vy | Set Vx = Vx XOR Vy | Bitwise XOR. If `VIP` quirk is **on**, also clear the VF register
8xy4 | ADD Vx, Vy | Set Vx = Vx + Vy, set VF = carry\* | VF is set to 1 if the result would exceed 255, set to 0 otherwise
8xy5 | SUB Vx, Vy | Set Vx = Vx - Vy, set VF = NOT borrow\* | VF is set to 0 if the result would be less than zero, set to 1 otherwise
8xy6 | SHR Vx {, Vy} | Set Vx = Vy >> 1, VF is set to Vy&1 before the shift\* | If `LSQ` quirk is **on**, the instruction operates on Vx instead of Vy
8xy7 | SUBN Vx, Vy | Set Vx = Vy - Vx, set VF = NOT borrow\* | VF is set to 0 if the result would be less than zero, set to 1 otherwise
8xyE | SHL Vx {, Vy} | Set Vx = Vy << 1, VF is set to Vy&1 before the shift\* | If `LSQ` quirk is **on**, the instruction operates on Vx instead of Vy
9xy0 | SNE Vx, Vy | Skip next instruction if Vx != Vy |
Annn | LD I, addr | Set I = addr |
Bnnn | JP V0, addr | Jump to location addr + V0 | If `JMP` quirk is **on**, V{addr>>8} is used instead of V0
Cxkk | RND Vx, byte | Set Vx = random number AND byte | Vx = rnd(0,255) & byte 
Dxyn | DRW Vx, Vy, n | Display n-byte sprite (XOR with the video memory) starting at memory location I at (Vx, Vy), set VF = collision | VF if set to 1 if **any** existing pixel of the screen was already set to 1 and the sprite overwrote it with 1, making it 0, and VF is set to 0 otherwise. If the sprite is positioned so a part of it is outside of the display width, it wraps around to the opposite side of the screen
Ex9E | SKP Vx | Skip next instruction if key with the value of Vx is pressed |
ExA1 | SKNP Vx | Skip next instruction if key with the value of Vx is not pressed |
Fx07 | LD Vx, DT | Set Vx to the value of delay timer register |
Fx0A | LD Vx, K | Block the execution, wait for keyboard input and store the result digit into Vx |
Fx15 | LD DT, Vx | Set delay timer register to the value of Vx | 
Fx18 | LD ST, Vx | Set sound timer register to the value of Vx |
Fx1E | ADD I, Vx | Set I = I + Vx |
Fx29 | LD F, Vx | Set I = location of sprite for digit stored in Vx |
Fx33 | LD B, Vx | Store BCD representation of Vx in memory locations I, I+1, and I+2 |
Fx55 | LD [I], Vx | Store registers V0 through Vx in memory starting at location I | If `STQ` quirk is **off**, the instruction modifies I to I + x + 1
Fx65 | LD Vx, [I] | Read registers V0 through Vx from memory starting at location I | If `STQ` quirk is **off**, the instruction modifies I to I + x + 1

\* If `CRY` quirk is on, modify the target register **after** setting the VF register in this operation

## Credits

Created by Luxferre in 2023, released into public domain.

Made in Ukraine.
