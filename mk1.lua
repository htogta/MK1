math.randomseed(os.time()) -- for rng later on

local function perror(msg)
  io.stderr:write(string.format("Error: %s\n", msg))
  os.exit(1)
end

local function perror_at(token, msg)
  io.stderr:write(string.format("Error at '%s': %s\n", token, msg))
  os.exit(1)
end

local function read_source(path)
  local f = io.open(path, "r")
  if not f then perror("Could not open " .. path) end
  local text = f:read("*a")
  f:close()
  return text
end

local function tokenize(source)
  local tokens = {}
  local in_comment = false
  for tok in source:gmatch("%S+") do
    if tok == "(" then in_comment = true
    elseif tok == ")" then in_comment = false
    elseif not in_comment then table.insert(tokens, tok)
    end
  end

  if in_comment then perror("comment never closed with ')'") end

  return tokens
end

-- go through the list of tokens, replacing all pseudo-instructions with their expanded forms
local function pseudo_instructions(tokens)
  local expanded = {} -- we append our tokens to this list afterwards
  local callcounter = 0

  -- function for generating random/unique labels for use with "call"
  local function make_ret_label()
    -- these are the allowed characters in our random unique labels:
    local chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
    local s = {} -- our random 8-character string will be stored in here
    for i = 1, 8 do
      local idx = math.random(#chars)
      s[i] = chars:sub(idx, idx)
    end

    local output = "call-" .. table.concat(s) .. callcounter
    callcounter = callcounter + 1
    return output
  end

  local i = 1
  while i <= #tokens do
    local tok = tokens[i]

    if tok == "call" then
      local retlabel = make_ret_label()
      table.insert(expanded, "@" .. retlabel)
      table.insert(expanded, "psh3")
      table.insert(expanded, "jmp3")
      table.insert(expanded, "." .. retlabel)
    elseif tok == "return" then
      table.insert(expanded, "pop3")
      table.insert(expanded, "jmp3")
    else -- normal token
      table.insert(expanded, tok)
    end

    i = i + 1
  end

  return expanded
end

local function handle_labels(tokens)
  local labels = {}
  local pc = 0

  -- first pass, store all label declarations with pc value
  local i = 1
  while i <= #tokens do 
    local tok = tokens[i]

    if tok:sub(1, 1) == "." then -- label declaration
      local label_name = tok:sub(2)
      local exists = labels[label_name]
      if exists then perror_at(tok, "label defined twice")
      else labels[label_name] = pc end
    elseif tok:sub(1, 1) == "@" or 
    (tok:sub(1, 1) == "?" and tok:sub(2, 2) == "@") then -- label push
      pc = pc + 1 + 3 -- 1 byte for LIT, plus 3 for word
    elseif tok:sub(1, 1) == "#" or 
    (tok:sub(1, 1) == "?" and tok:sub(2, 2) == "#") then -- literal hex
      local has_skip = tok:sub(1, 1) == "?"
      local digits
      if has_skip then digits = tok:sub(3) else digits = tok:sub(2) end
      if (#digits ~= 2) and (#digits ~= 4) and (#digits ~= 6) and (#digits ~= 8) then
        perror_at(tok, "invalid number of hex digits in literal (must be 2, 4, 6, or 8)")
      end
      pc = pc + 1 + (#digits // 2) -- 1 byte for LIT, plus n more for immediate value
    elseif tok:sub(1, 1) == "^" then -- raw hex
      local digits = tok:sub(2)
      if #digits % 2 ~= 0 then
        perror_at(tok, "expected even number of hex digits in raw hex")
      end
      pc = pc + (#digits // 2)
    elseif tok:sub(1, 1) == "$" then -- string literal
      local text = tok:sub(2)
      pc = pc + #text
    else -- normal opcode
      pc = pc + 1
    end
    
    i = i + 1
  end

  -- second pass, convert all labels to lit instructions
  local expanded = {}
  local j = 1
  while j <= #tokens do
    local tok = tokens[j]

    if tok:sub(1, 1) == "@" or
    (tok:sub(1, 1) == "?" and tok:sub(2, 2) == "@") then
      local has_skip = tok:sub(1, 1) == "?"
      local label_name
      if has_skip then label_name = tok:sub(3) else label_name = tok:sub(2) end
      local pc_value = labels[label_name]
      if not pc_value then perror_at(tok, "label declaration not found") end

      local pc_hex = string.format("%0" .. 6 .. "x", pc_value)
      local literal
      if has_skip then literal = "?#" .. pc_hex else literal = "#" .. pc_hex end
      table.insert(expanded, literal)
    elseif tok:sub(1, 1) ~= "." then -- don't insert label declarations
      table.insert(expanded, tok)
    end

    j = j + 1
  end

  return expanded
end

local function assemble(opcodes)
  local binary = {}

  local opmap = {
    add = 0x00, ["and"] = 0x01, xor = 0x02, shf = 0x03, 
    swp = 0x04, cmp = 0x05, str = 0x06, lod = 0x07, 
    dup = 0x08, drp = 0x09, psh = 0x0a, pop = 0x0b, 
    jmp = 0x0c, lit = 0x0d, fet = 0x0e, nop = 0x0f,
  }

  local function emit_op(op, a, skip)
    local instr = 0x80
    if skip then instr = instr | 0x40 end
    instr = instr | (a & 0x03 << 4)
    instr = instr | (op & 0x0f)
    table.insert(binary, instr)
  end

  local i = 1
  while i <= #opcodes do
    local tok = opcodes[i]
    if tok:sub(1, 1) == "#" or
    (tok:sub(1, 1) == "?" and tok:sub(2, 2) == "#") then -- literal hex
      local digits
      if tok:sub(1, 1) == "?" then digits = tok:sub(3) else digits = tok:sub(2) end
      -- we already know that the number of digits is correct, no need to check again
      emit_op(opmap.lit, (#digits // 2) - 1, tok:sub(1, 1) == "?")
    elseif tok:sub(1, 1) == "^" then -- raw hex
      local hexstr = tok:sub(2)
      -- no need to check if it's even, we already did that
      for i = 1, #hexstr - 1, 2 do
        local bytechars = hexstr:sub(i, i + 1)
        local byte = tonumber(bytechars, 16)
        table.insert(binary, byte)
      end
    elseif tok:sub(1, 1) == "$" then -- string
      local text = tok:sub(2)
      for i = 1, #text do
        local ch = text:sub(i, i)
        table.insert(binary, ch:byte())
      end
    else -- standard opcode
      local has_skip, opcode, num = tok:match("(%??)(%l%l%l)(%d)")
      if not opmap[opcode] then
        perror_at(tok, "unrecognized opcode mnemonic") 
      end
      if not num then
        perror_at(tok, "missing number suffix after mnemonic")
      end
      emit_op(opmap[opcode], tonumber(num), has_skip == "?")
    end

    i = i + 1
  end

  return binary
end

local function write_binary(filename, bytes)
  local f, err = io.open(filename, "wb")
  if not f then perror("Failed to open " .. filename) end

  local data = {}
  for i = 1, #bytes do data[i] = string.char(bytes[i] & 0xff) end
  f:write(table.concat(data))
  f:close()
end

-- "main", the assembler loop
local input = arg[1]
local output = arg[2] or "out.okb"

local function print_usage()
  io.stdout:write("Usage: lua mk1.lua input.mk1 [out.okb]\n")
end

if not input then 
  print_usage()
  os.exit(1)
end

local source = read_source(input)
local tokens = tokenize(source)
local no_pseudos = pseudo_instructions(tokens)
local handled_labels = handle_labels(no_pseudos)
local binary = assemble(handled_labels)
write_binary(output, binary)
