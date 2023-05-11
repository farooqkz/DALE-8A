#!/sbin/env awk -f
# DALE-8A: a POSIX-compatible CHIP-8 emulator for AWK
# Depends on the tgl.awk library, stty, time and od commands
# Usage (w/o wrapper):
# LANG=C awk -f tgl.awk -f dale8a.awk [-v vars ...] -- prog.ch8
# Available vars to set:
# - CLOCK_FACTOR (1 and above, default 20) - CPU cycles per frame
# - PXL_COLOR (1 to 7) - foreground color of the screen
# - BG_COLOR (0 to 7) - background color of the screen
# - SBAR_COLOR (1 to 7) - foreground color of the statusbar
# - SBAR_BG_COLOR (0 to 7) - background color of the statusbar
# - EMU_QUIRK_[LSQ|STQ|VIP|JMP|CRY] - emulation quirk flags
#
# See README.md for details
#
# Created by Luxferre in 2023, released into public domain

# fatal error reporting function
function trapout(msg) {
  shutdown()
  cmd = "cat 1>&2"
  printf("Fatal: %s\n", msg) | cmd
  close(cmd)
  exit(1)
}
# graceful shutdown function - restore the terminal state
function shutdown() {printf(SCR_CLR); altbufoff(); close(KEY_INPUT_STREAM); setterm(0)}

function reportUnknownInstruction(msg) {
  msg = sprintf("unknown instruction at addr %04X: %02X%02X", pc-2, b1, b2)
  trapout(msg)
}

# terminal control routines
function altbufon() {printf("\033[?47h")}
function altbufoff() {printf("\033[?47l")}

# render the statusbar + main screen area
# all main rendering is done offscreen and then a single printf is called
function drawscreen(s, i) {
  s = SCR_CLR SCR_SBAR # start with statusbar + main color mode switch
  for(i=64;i<2048;i++) { # render two pixel lines into one text line
    s = s SCR_PXL[screen[i-64] + 2*screen[i]]
    if(i%128 == 127) {
      s = s "\n"
      i += 64
    }
  }
  s = s SCR_SRESET # reset styling
  printf("%s", s) # output everything
}

# clear the screen (from inside the engine)
function clearScreen(i) {
  for(i=0;i<2048;i++) screen[i] = 0
  renderScheduled = 1
}

# sprite drawing routine
function drawSprite(x, y, bLen, i, j, realbyte, ind) {
  V[15] = 0
  for(i=0;i<bLen;i++) {
    realbyte = ram[iReg + i]
    for(j=0;realbyte>0;j++) { # loop while the byte is alive
      if(realbyte % 2) { # do anything only if the bit is set
        ind = ((y + i) % 32) * 64 + ((x + 7 - j) % 64) # calc the index
        if(screen[ind] == 1) {
          V[15] = 1
          screen[ind] = 0
        }
        else screen[ind] = 1
      }
      realbyte = int(realbyte / 2) # shift byte value
    }
  }
  renderScheduled = 1
}

function readkeynb(key) { # read a key, non-blocking fashion
  KEY_INPUT_STREAM | getline key # open the subprocess
  key = int(key) # read the key state
  close(KEY_INPUT_STREAM)
  if(key == 27) {shutdown(); exit(0)} # exit on Esc
  if(key in KBD_LAYOUT) { # if found, update the state and return the index
    key = KBD_LAYOUT[key]
    inputState[key] = 3 # introduce frame delay for the keypress
    return key
  }
  return -1 # if not found, return -1
}

function readkey(c) { # wait for a keypress and read the result
  drawscreen() # refresh the screen before blocking
  # drain input states
  for(i=0;i<16;i++) inputState[i] = 0
  # drain timers
  dtReg = stReg = 0
  do c = readkeynb() # read the code
  while(c < 0)
  inputState[c] = 0;
  return c
}

function wcf(dest, value, flag) { # write the result with carry/borrow flag
  V[dest] = value % 256
  V[15] = flag ? 1 : 0
  if(EMU_QUIRK_CRY) V[dest] = value % 256
}

# main CPU loop (direct adapted port from JS)

function cpuLoop() {
  if(skip) { # skip once if marked so
    pc += 2
    skip = 0
  }
  b1 = ram[pc++]%256  # read the first byte and advance the counter
  b2 = ram[pc++]%256  # read the second byte and advance the counter
  d1 = int(b1/16) # extract the first instruction digit
  d2 = b1 % 16    # extract the second instruction digit
  d3 = int(b2/16) # extract the third instruction digit
  d4 = b2 % 16    # extract the fourth instruction digit
  nnn = d2 * 256 + b2 # extract the address for NNN style instructions
  if(pc < 512 || pc > 4095) trapout("instruction pointer out of bounds")
  #  Main challenge begins in 3... 2... 1...
  if(d1 == 0 && d2 == 0 && d3 == 14) { # omit everything except 00E0 and 00EE
    if(d4 == 0) clearScreen() # pretty obvious, isn't it?
    else if(d4 == 14) {if(sp > 0) pc = stack[--sp]} # return from the subroutine
    else reportUnknownInstruction()
  }
  else if(d1 == 1) pc = nnn # unconditional jumpstyle
  else if(d1 == 2) {stack[sp++] = pc; pc = nnn} # subroutine call
  # Skip the following instruction if the value of register V{d2} equals {b2}
  else if(d1 == 3) {if(V[d2] == b2) skip = 1}
  # Skip the following instruction if the value of register V{d2} is not equal to {b2}
  else if(d1 == 4) {if(V[d2] != b2) skip = 1}
  # Skip the following instruction if the value of register V{d2} equals V{d3}
  else if(d1 == 5) {if(V[d2] == V[d3]) skip = 1 }
  else if(d1 == 6) V[d2] = b2 # Store number {b2} in register V{d2}
  else if(d1 == 7) V[d2] = (V[d2] + b2) % 256 # Add the value {b2} to register V{d2}
  else if(d1 == 8) { # Monster #1
  # for all instructions in this section, d4 is the selector and d2 and d3 are the X and Y parameters respectively
    if(d4 == 0) V[d2] = V[d3] # Store the value of register VY in register VX
    # Set VX to VX OR VY
    else if(d4 == 1) {V[d2] = bw_or(V[d2], V[d3]); if(EMU_QUIRK_VIP) V[15] = 0}
    # Set VX to VX AND VY
    else if(d4 == 2) {V[d2] = bw_and(V[d2], V[d3]); if(EMU_QUIRK_VIP) V[15] = 0}
    # Set VX to VX XOR VY
    else if(d4 == 3) {V[d2] = bw_xor(V[d2], V[d3]); if(EMU_QUIRK_VIP) V[15] = 0}
    else if(d4 == 4) { # Add the value of register VY to register VX with overflow recorded in VF
      nnn = V[d2] + V[d3]
      wcf(d2, nnn, nnn > 255)
    }
    else if(d4 == 5) { # Set VX = VX - VY with underflow recorded in VF
      nnn = V[d2] - V[d3]
      wcf(d2, nnn + 256, nnn >= 0)
    }
    else if(d4 == 6) { # Store the value of register VY shifted right one bit in register VX, set register VF to the least significant bit prior to the shift
      if(EMU_QUIRK_LSQ) d3 = d2
      wcf(d2, int(V[d3]/2), V[d3]%2)
    }
    else if(d4 == 7) { # Set VX = VY - VX with underflow recorded in VF
      nnn = V[d3] - V[d2]
      wcf(d2, nnn + 256, nnn >= 0)
    }
    else if(d4 == 14) { # Store the value of register VY shifted left one bit in register VX, set register VF to the most significant bit prior to the shift
      if(EMU_QUIRK_LSQ) d3 = d2
      wcf(d2, V[d3]*2, int(V[d3]/128))
    }
    else reportUnknownInstruction()
  }
  # Skip the following instruction if the value of register V{d2} is not equal to the value of register V{d3}
  else if(d1 == 9) {if(V[d2] != V[d3]) skip = 1}
  else if(d1 == 10) iReg = nnn # Store memory address NNN in register I
  else if(d1 == 11) {
    if(EMU_QUIRK_JMP) pc = nnn + V[d2]
    else pc = nnn + V[0] # Jump to address NNN + V0
  }
  else if(d1 == 12) V[d2] = bw_and(int(rand()*256)%256, b2) # Set V{d2} to a random number with a mask of {b2}
  # Draw a sprite at position V{d2}, V{d3} with {d4} bytes of sprite data starting at the address stored in I
  # Set VF to 01 if any set pixels are changed to unset, and 00 otherwise
  else if(d1 == 13) drawSprite(V[d2], V[d3], d4)
  else if(d1 == 14) {
    # Skip the following instruction if the key corresponding to the hex value currently stored in register V{d2} is pressed
    if(b2 == 158) {if(inputState[V[d2]] > 0) skip = 1}
    # Skip the following instruction if the key corresponding to the hex value currently stored in register V{d2} is not pressed
    else if(b2 == 161) {if(inputState[V[d2]] == 0) skip = 1}
    else reportUnknownInstruction()
  }
  else if(d1 == 15) { # Monster #2
    # d2 is the parameter X for all these instructions, b2 is the selector
    if(b2 == 7) V[d2] = dtReg # Store the current value of the delay timer in register VX
    else if(b2 == 10) V[d2] = readkey() # Wait for a keypress and store the result in register VX
    else if(b2 == 21) dtReg = V[d2] # Set the delay timer to the value of register VX
    else if(b2 == 24) stReg = V[d2] # Set the sound timer to the value of register VX
    else if(b2 == 30) iReg = (iReg + V[d2]) % 65536 # Add the value stored in register VX to register I
    # Set I to the memory address of the sprite data corresponding to the hexadecimal digit stored in register VX
    else if(b2 == 41) iReg = (128 + V[d2] * 5) % 65536
    else if(b2 == 51) { # Store the binary-coded decimal equivalent of the value stored in register VX at addresses I, I+1, and I+2
      nnn = V[d2]
      ram[iReg % 4096] = int(nnn / 100)
      ram[(iReg % 4096) + 1] = int((nnn % 100) / 10)
      ram[(iReg % 4096) + 2] = nnn % 10
    }
    else if(b2 == 85) {
      # Store the values of registers V0 to VX inclusive in memory starting at address I
      # I is set to I + X + 1 after operation
      for(nnn=0;nnn<=d2;nnn++) ram[(iReg+nnn) % 4096] = V[nnn]
      if(!EMU_QUIRK_STQ) iReg = (iReg + d2 + 1) % 65536
    }
    else if(b2 == 101) {
      # Fill registers V0 to VX inclusive with the values stored in memory starting at address I
      # I is set to I + X + 1 after operation
      for(nnn=0;nnn<=d2;nnn++) V[nnn] = ram[(iReg+nnn) % 4096]
      if(!EMU_QUIRK_STQ) iReg = (iReg + d2 + 1) % 65536
    }
    else reportUnknownInstruction()
  }
  else reportUnknownInstruction()
}

# get current Unix timestamp with millisecond precision with various methods
function timestampms(cmd, res) {
  cmd = "echo $EPOCHREALTIME"
  cmd | getline res
  close(cmd)
  sub(/[,\.]/,"", res)
  res = int(res)
  if(res) return res / 1000 # micro=>milli
  # otherwise we need to use an alternate, POSIX-compatible method
  cmd = "date +%s"
  cmd | getline res
  close(cmd)
  return int(res) * 1000 # s=>milli
}

# determine the amount of empty cycles needed to fill a single frame
function hostprofile(cf, i, cps, sc, st, et) {
  sc = 2000000 # this is an arbitrarily large (but not too large) cycle count
  do {
    sc += 200000
    st = timestampms()
    a = 0
    for(i=0;i<sc;i++) a += i
    et = timestampms()
  } while(et == st)
  # now, we have our cps metric
  cps = 1000 * sc / (int(et) - int(st))
  # but we need 1/60 second and also consider other operations
  return int(cps / 60 - cf - 16)
}

# main code starts here

BEGIN {
  if(ARGC < 2) trapout("no ROM file specified!")
  # preload the ROM - starting index is 0
  PRG_FNAME = ARGV[1]
  print "Loading", PRG_FNAME
  PRG_LEN = loadbin(PRG_FNAME, PRG_ROM, 0, 1)
  if(PRG_LEN < 1) trapout("could not read ROM!")
  PRG_END_ADDR = 512 + PRG_LEN # all CHIP-8 ROMs start at 0x200 = 512
  srand() # init the PRNG
  KEY_INPUT_STREAM = "od -tu1 -w1 -An -N1 -v"
  # tweak the per-frame performance here
  clockFactor = int(CLOCK_FACTOR > 0 ? CLOCK_FACTOR : 20)
  print "Profiling the frame timing..."
  framecycle = hostprofile(clockFactor) # get the amount of host cycles to skip 
  printf "Detected %u cycles per frame\n", framecycle
  # read the quirk flags from the filename and environment
  EMU_QUIRK_LSQ = !!EMU_QUIRK_LSQ
  EMU_QUIRK_STQ = !!EMU_QUIRK_STQ
  EMU_QUIRK_VIP = !!EMU_QUIRK_VIP
  EMU_QUIRK_JMP = !!EMU_QUIRK_JMP
  EMU_QUIRK_CRY = !!EMU_QUIRK_CRY
  if(PRG_FNAME ~ /\.sl\.ch8$/ || PRG_FNAME ~ /\.ls\.ch8$/) # check the extension
    EMU_QUIRK_LSQ = EMU_QUIRK_STQ = 1 # both quirks on
  else if(PRG_FNAME ~ /\.l\.ch8$/) EMU_QUIRK_LSQ = 1 # only LSQ on
  else if(PRG_FNAME ~ /\.s\.ch8$/) EMU_QUIRK_STQ = 1 # only STQ on
  qstatus = "|"
  if(EMU_QUIRK_LSQ) qstatus = qstatus " LSQ"
  if(EMU_QUIRK_STQ) qstatus = qstatus " STQ"
  if(EMU_QUIRK_VIP) qstatus = qstatus " VIP"
  if(EMU_QUIRK_JMP) qstatus = qstatus " JMP"
  if(EMU_QUIRK_CRY) qstatus = qstatus " CRY"
  # init main and statusbar color codes (from 1 to 7)
  if(!PXL_COLOR || PXL_COLOR > 7) PXL_COLOR = 2 # green by default
  if(!SBAR_COLOR || SBAR_COLOR > 7) SBAR_COLOR = 3 # yellow by default
  if(!BG_COLOR || BG_COLOR > 7) BG_COLOR = 0 # black backgrounds by default
  if(!SBAR_BG_COLOR || SBAR_BG_COLOR > 7) SBAR_BG_COLOR = 0 
  # init some string constants and parameters
  SCR_CLR = sprintf("\033[2J")
  SCR_PXL[0] = " " # empty space
  SCR_PXL[1] = wctomb(9600) # Unicode upper-half block
  SCR_PXL[2] = wctomb(9604) # Unicode lower-half block
  SCR_PXL[3] = wctomb(9608) # Unicode rectangular block
  HR = ""
  for(i=0;i<64;i++) HR = HR "-"
  SCR_SBAR = sprintf("\033[3%d;1;4%dmDALE-8A | %s %s\n" \
      "%s\n\033[3%d;4%dm", SBAR_COLOR, SBAR_BG_COLOR, PRG_FNAME, \
      qstatus, HR, PXL_COLOR, BG_COLOR)
  SCR_SRESET = sprintf("\033[0m\033[0;0H")
  # init CHR ROM - starting index is 1
  split("240 144 144 144 240 32 96 32 32 112 240 16 240 128 240 240 16 " \
        "240 16 240 144 144 240 16 16 240 128 240 16 240 240 128 240 144 " \
        "240 240 16 32 64 64 240 144 240 144 240 240 144 240 16 240 240 " \
        "144 240 144 144 224 144 224 144 224 240 128 128 128 240 224 144 " \
        "144 144 224 240 128 240 128 240 240 128 240 128 128", CHR_ROM)
  # init keyboard layout
  split("120 49 50 51 113 119 101 97 115 100 122 99 52 114 102 118", kbdx)
  for(i=1;i<=16;i++) KBD_LAYOUT[kbdx[i]] = i - 1
  # init main registers, stack, RAM and screen - starting index for all is 0
  for(i=0;i<4096;i++) {
    if(i < 16) V[i] = inputState[i] = 0
    if(i < 1792) stack[i] = 0 # also init call stack 
    if(i < 2048) screen[i] = 0 # screen is 2048 bytes long instead of bits
    if(i>= 128 && i < 208) { # a byte from CHR ROM which is 80 bytes long
      j = i - 127
      ram[i] = int(CHR_ROM[j]) % 256
      delete CHR_ROM[j]
    }
    else if(i>= 512 && i < PRG_END_ADDR) { # a byte from PRG ROM
      j = i - 512
      ram[i] = int(PRG_ROM[j]) % 256
      delete PRG_ROM[j]
    }
    else ram[i] = 0 # everything else must be initialized to 0
  }
  # main execution logic starts here
  altbufon() # enter the alternative screen buffer
  setterm(3) # enter the non-blocking input mode before the event loop
  pc = 512 # start at instruction 0x200
  iReg = dtReg = stReg = skip = 0 # init I, DT and ST registers and skip flag
  renderScheduled = 0 # only render the screen when necessary
  b1 = b2 = d1 = d2 = d3 = d4 = nnn = sp = 0 # init different opcode parts
  while(1) { # our event loop is here
    for(i=0;i<clockFactor;i++) cpuLoop() # call main CPU loop CF times
    if(renderScheduled) {
      drawscreen() # render the current screen state
      renderScheduled = 0
    }
    # timer register loops
    if(dtReg > 0) dtReg--
    if(stReg > 0) stReg--
    # decrement input states
    for(i=0;i<16;i++) if(inputState[i] > 0) inputState[i]--
    # read and update current key states
    readkeynb()
    a=0
    for(i=0;i<framecycle;i++) a+=i # sleep on 1/60 sec, more efficiently
  }
  shutdown() # restore the terminal state and exit
}
