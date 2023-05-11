# The Great Library of useful AWK functions
# Fully POSIX-compatible but sometimes depends on other POSIX commands
# Use with your programs like this:
# LANG=C awk -f tgl.awk -f your_prog.awk [args]
#
# Current functionality:
# * single character input: setterm, getchar
# * ASCII and UTF-8 codepoint conversion: ord, wctomb, mbtowc
# * loading binary files as decimal integers into arrays: loadbin
# * saving binary files from arrays with decimal integers: savebin
# * tangent and cotangent functions: tan, cotan
# * signum, floor and ceiling functions: sign, floor, ceil
# * test for native bitwise operation support: bw_native_support
# * reimplementation of most bitwise operations (unsigned 32-bit):
# - NOT: bw_compl
# - AND: bw_and
# - OR: bw_or
# - XOR: bw_xor
# - NAND: bw_nand
# - NOR: bw_nor
# - >>: bw_rshift
# - <<: bw_lshift
#
# Created by Luxferre in 2023, released into public domain

# set/restore the terminal input mode using stty
# usage: setterm(0|1|2|3)
# 0 - restore the original terminal input mode
# 1 - blocking single-character input with echo
# 2 - blocking single-character input without echo
# 3 - non-blocking single-character input without echo
# in pipes, this function doesn't do anything
# (but returns 0 since it's not an error)
# otherwise an actual stty exit code is returned
function setterm(mode, cmd) {
  if(system("stty >/dev/null 2>&1")) return 0 # exit code 0 means we're in a tty
  if(!TGL_TERMMODE) { # cache the original terminal input mode
    (cmd = "stty -g") | getline TGL_TERMMODE
    close(cmd)
  }
  if(mode == 1) cmd = "-icanon"
  else if(mode == 2) cmd = "-icanon -echo"
  else if(mode == 3) cmd = "-icanon time 0 min 0 -echo"
  else cmd = TGL_TERMMODE # restore the original mode
  return system("stty " cmd ">/dev/null 2>&1") # execute the stty command
}

# getchar emulation using od
# caches the read command for further usage
# also able to capture null bytes, unlike read/printf approach
# use in conjunction with setterm to achieve different input modes
# setting LANG=C envvar is recommended, for GAWK it is required
# usage: getchar() => integer
function getchar(c) {
  if(!TGL_GCH_CMD) TGL_GCH_CMD = "od -tu1 -w1 -N1 -An -v" # first time usage
  TGL_GCH_CMD | getline c
  close(TGL_GCH_CMD)
  return int(c)
}

# get the ASCII code of a character
# setting LANG=C envvar is recommended, for GAWK it is required
# usage: ord(c) => integer
function ord(c, b) {
  # init char-to-ASCII mapping if it's not there yet
  if(!TGL_ORD["#"]) for(b=0;b<256;b++) TGL_ORD[sprintf("%c", b)] = b
  return int(TGL_ORD[c])
}

# encode a single integer UTF-8 codepoint into a byte sequence in a string
# setting LANG=C envvar is recommended, for GAWK it is required
# usage: wctomb(code) => string
# we can safely use the string type for all codepoints above 0 as all
# multibyte sequences have a high bit set, so no null byte is there
# for invalid codepoints, an empty string will be returned
function wctomb(code, s) {
  code = int(code)
  if(code < 0 || code > 1114109) s = ""  # invalid codepoint
  else if(code < 128) s = sprintf("%c", code) # single byte
  else if(code < 2048) # 2-byte sequence
    s = sprintf("%c%c", \
      192 + (int(code/64) % 32), \
      128 + (code % 64))
  else if(code < 65536) # 3-byte sequence
    s = sprintf("%c%c%c", \
      224 + (int(code/4096) % 16), \
      128 + (int(code/64) % 64), \
      128 + (code % 64))
  else # 4-byte sequence
    s = sprintf("%c%c%c%c", \
      240 + (int(code/262144) % 8), \
      128 + (int(code/4096) % 64), \
      128 + (int(code/64) % 64), \
      128 + (code % 64))
  return s
}

# decode a byte string into a UTF-8 codepoint
# setting LANG=C envvar is recommended, for GAWK it is required
# usage: mbtowc(s) => integer
# decoding stops on the first encountered invalid byte
function mbtowc(s, len, code, b, pos) {
  len = length(s)
  code = 0
  for(pos=1;pos<=len;pos++) {
    code *= 64 # shift the code 6 bits left
    b = ord(substr(s, pos, 1))
    if(pos == 1) { # expect a single or header byte
      if(b < 128) {code = b; break} # it resolves into a single byte
      else if(b >= 192 && b < 224) # it's a header byte of 2-byte sequence
        code += b % 32
      else if(b >= 224 && b < 240) # it's a header byte of 3-byte sequence
        code += b % 16
      else if(b >= 240) # it's a header byte of 4-byte sequence
        code += b % 8
      else break # a trailer byte in the header position is invalid
    }
    else if(b >= 128 && b < 192) # it must be a trailer byte
      code += b % 64
    else break # a header byte in the trailer position is invalid
  }
  return code
}

# load any binary file into an AWK array (0-indexed), depends on od
# returns the resulting array length
# usage: loadbin(fname, arr, len, wordsize) => integer
# len parameter is optional, specifies how many bytes to read
# (if 0 or unset, read everything)
# wordsize parameter is optional, 1 byte by default
# multibyte words are considered little-endian
function loadbin(fname, arr, len, wordsize, cmd, i) {
  wordsize = int(wordsize)
  if(wordsize < 1) wordsize = 1
  len = int(len)
  i = (len > 0) ? (" -N" len " ") : ""
  cmd = "od -tu" wordsize " -An -w" wordsize i " -v \"" fname "\""
  # every line should be a single decimal integer (with some whitespace)
  i = 0
  while((cmd | getline) > 0)  # read the next line from the stream
    if(NF) arr[i++] = int($1) # read the first and only field
  close(cmd) # close the od process
  return i
}

# save an AWK array (0-indexed) into a binary file
# setting LANG=C envvar is recommended, for GAWK it is required
# returns the amount of written elements
# usage: savebin(fname, arr, len, wordsize) => integer
# wordsize parameter is optional, 1 byte by default
# multibyte words are considered little-endian
function savebin(fname, arr, len, wordsize, i, j) {
  wordsize = int(wordsize)
  if(wordsize < 1) wordsize = 1
  printf("") > fname # truncate the file and open the stream
  for(i=0;i<len;i++) {
    if(wordsize == 1) printf("%c", arr[i]) >> fname
    else # we have a multibyte word size
      for(j=0;j<wordsize;j++)
        printf("%c", int(arr[i]/2^(8*j))%256) >> fname
  }
  close(fname) # close the output file
  return i
}

# the missing tangent/cotangent functions

function tan(x) {return sin(x)/cos(x)}
function cotan(x) {return cos(x)/sin(x)}

# the missing sign/floor/ceil functions

function sign(x) {return x < 0 ? -1 : !!x}
function floor(x, f) {
  f = int(x)
  if(x == f) return x
  else return x >= 0 ? f : (f - 1) 
}
function ceil(x, f) {
  f = int(x)
  if(x == f) return x
  else return x >= 0 ? (f + 1) : f
}

# Bitwise operations section

# test if the AWK engine has non-POSIX bitwise operation functions
# (and, or, xor, compl, lshift, rshift) implemented natively:
# if compl is missing, it will be concatenated with 1 and equal to 1
# so the inverse of this condition will be the result
function bw_native_support() {return (compl (1) != 1)}

# now, the implementation of the operations themselves
# note that all complements are 32-bit and all operands must be non-negative

function bw_compl(a) {return 4294967295 - int(a)}
function bw_lshift(a, b) {for(;b>0;b--) a = int(a/2);return a}
function bw_rshift(a, b) {for(;b>0;b--) a *= 2;return int(a)}
function bw_and(a, b, v, r) {
  v = 1; r = 0
  while(a > 0 || b > 0) {
    if((a%2) == 1 && (b%2) == 1) r += v
    a = int(a/2)
    b = int(b/2)
    v *= 2
  }
  return int(r)
}
function bw_or(a, b, v, r) {
  v = 1; r = 0
  while(a > 0 || b > 0) {
    if((a%2) == 1 || (b%2) == 1) r += v
    a = int(a/2)
    b = int(b/2)
    v *= 2
  }
  return int(r)
}
function bw_xor(a, b, v, r) {
  v = 1; r = 0
  while(a > 0 || b > 0) {
    if((a%2) != (b%2)) r += v
    a = int(a/2)
    b = int(b/2)
    v *= 2
  }
  return int(r)
}
function bw_nand(a, b) {return bw_compl(bw_and(a,b))}
function bw_nor(a, b) {return bw_compl(bw_or(a,b))}

