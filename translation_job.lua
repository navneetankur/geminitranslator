#!/usr/bin/env lua
-- translation_job.lua — translate Chinese webnovel chapters via Gemini batch API
--
-- Usage:
--   translation_job.lua send <to_translate_dir>   -> submits a batch, writes id to batch.txt
--   translation_job.lua get  <batch.txt> <out_dir> -> if done, writes translated files
--
-- Requires: curl, jq, and env var GEMINI_API_KEY

local MODEL   = "gemini-2.5-flash-lite"
local API     = "https://generativelanguage.googleapis.com/v1beta"
local KEY     = os.getenv("GEMINI_API_KEY")

----------------------------------------------------------------------
-- small helpers
----------------------------------------------------------------------

local function die(msg)
  io.stderr:write("error: " .. msg .. "\n")
  os.exit(1)
end

-- run a shell command, return stdout (trimmed) and success flag
local function sh(cmd)
  local f = assert(io.popen(cmd, "r"))
  local out = f:read("*a") or ""
  local ok = f:close()
  return (out:gsub("%s+$", "")), ok
end

local function file_exists(path)
  local f = io.open(path, "r")
  if f then f:close() return true end
  return false
end

local function read_file(path)
  local f = assert(io.open(path, "r"))
  local s = f:read("*a")
  f:close()
  return s
end

local function write_file(path, content)
  local f = assert(io.open(path, "w"))
  f:write(content)
  f:close()
end

-- shell-quote a single argument
local function q(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

-- numeric-aware sort key: "12.txt" sorts after "2.txt"
local function numkey(name)
  local n = name:match("^(%d+)")
  return n and tonumber(n) or math.huge
end

-- list *.txt files in dir (excluding prompt.txt), sorted numerically then by name
local function list_inputs(dir)
  local out = sh("ls -1 " .. q(dir) .. " 2>/dev/null")
  local files = {}
  for name in out:gmatch("[^\n]+") do
    if name:match("%.txt$") and name ~= "prompt.txt" then
      files[#files + 1] = name
    end
  end
  table.sort(files, function(a, b)
    local ka, kb = numkey(a), numkey(b)
    if ka ~= kb then return ka < kb end
    return a < b
  end)
  return files
end

----------------------------------------------------------------------
-- send
----------------------------------------------------------------------

local function cmd_send(indir)
  if not indir then die("usage: translation_job.lua send <dir>") end
  if not KEY then die("GEMINI_API_KEY is not set") end
  indir = indir:gsub("/+$", "")

  -- locate prompt file
  local prompt_path = indir .. "/prompt.txt"
  if not file_exists(prompt_path) then
    prompt_path = (os.getenv("HOME") or "") .. "/.config/geminitran/prompt.txt"
  end
  if not file_exists(prompt_path) then
    die("no prompt found at " .. indir .. "/prompt.txt or ~/.config/geminitran/prompt.txt")
  end

  local files = list_inputs(indir)
  if #files == 0 then die("no *.txt files to translate in " .. indir) end

  -- build one inline request object per file (jq handles escaping)
  local tmp = os.tmpname()
  local reqs = assert(io.open(tmp, "w"))
  for _, name in ipairs(files) do
    local one = sh(table.concat({
      "jq -nc",
      "--arg key " .. q(name),
      "--rawfile prompt " .. q(prompt_path),
      "--rawfile body " .. q(indir .. "/" .. name),
      q('{request:{contents:[{parts:[{text:($prompt + "\\n\\n" + $body)}]}]}, metadata:{key:$key}}'),
    }, " "))
    reqs:write(one, "\n")
  end
  reqs:close()

  -- wrap all requests into the batch payload
  local payload = os.tmpname()
  sh(table.concat({
    "jq -s",
    q('{batch:{display_name:"webnovel", input_config:{requests:{requests: .}}}}'),
    "<", q(tmp), ">", q(payload),
  }, " "))

  print("submitting " .. #files .. " chapter(s) to " .. MODEL .. " ...")
  local resp = sh(table.concat({
    "curl -sS -X POST",
    q(API .. "/models/" .. MODEL .. ":batchGenerateContent"),
    "-H " .. q("x-goog-api-key: " .. KEY),
    "-H " .. q("Content-Type: application/json"),
    "-d @" .. q(payload),
  }, " "))

  os.remove(tmp)
  os.remove(payload)

  -- the create call returns the long-running job; its .name is what we poll
  local batch_name = sh("printf %s " .. q(resp) .. " | jq -r '.name // empty'")
  if batch_name == "" then
    die("no batch name in response:\n" .. resp)
  end

  write_file("batch.txt", batch_name .. "\n")
  print("batch submitted: " .. batch_name)
  print("wrote id to batch.txt")
end

----------------------------------------------------------------------
-- get
----------------------------------------------------------------------

-- jq program that coalesces the two known API result shapes (Operation
-- wrapper vs. Batch resource) into a flat [{key, text}] stream.
local EXTRACT = [[
  ( .response.inlinedResponses.inlinedResponses
    // .response.inlinedResponses
    // .dest.inlinedResponses.inlinedResponses
    // .dest.inlinedResponses
    // [] ) as $rs
  | $rs[]
  | { key: (.metadata.key // .metadata // "unknown"),
      text: ( [ (.response.candidates[]?.content.parts[]?.text) ] | join("") ) }
  | "\(.key)\t\(.text | @base64)"
]]

local function cmd_get(batchfile, outdir)
  if not batchfile or not outdir then
    die("usage: translation_job.lua get <batch.txt> <out_dir>")
  end
  if not KEY then die("GEMINI_API_KEY is not set") end
  outdir = outdir:gsub("/+$", "")

  local batch_name = read_file(batchfile):gsub("%s+", "")
  if batch_name == "" then die("empty batch id in " .. batchfile) end

  local resp = sh(table.concat({
    "curl -sS",
    q(API .. "/" .. batch_name),
    "-H " .. q("x-goog-api-key: " .. KEY),
  }, " "))

  -- always keep the raw response so we can inspect / adjust paths if needed
  write_file("batch_result.json", resp .. "\n")

  local state = sh("printf %s " .. q(resp) ..
    " | jq -r '.metadata.state // .state // (if .done then \"DONE\" else \"RUNNING\" end) // \"UNKNOWN\"'")
  print("batch state: " .. state)

  if not (state:match("SUCCEEDED") or state == "DONE") then
    if state:match("FAILED") or state:match("CANCELLED") or state:match("EXPIRED") then
      die("batch did not succeed (state=" .. state .. "); see batch_result.json")
    end
    print("not finished yet — try again later. (raw saved to batch_result.json)")
    return
  end

  os.execute("mkdir -p " .. q(outdir))

  local rows = sh("printf %s " .. q(resp) .. " | jq -r " .. q(EXTRACT))
  if rows == "" then
    die("job succeeded but no responses extracted — inspect batch_result.json to " ..
        "confirm the JSON path, then adjust the EXTRACT filter")
  end

  local count = 0
  for line in rows:gmatch("[^\n]+") do
    local key, b64 = line:match("^([^\t]*)\t(.*)$")
    if key and key ~= "" then
      local text = sh("printf %s " .. q(b64) .. " | base64 -d")
      write_file(outdir .. "/" .. key, text)
      count = count + 1
      print("  wrote " .. outdir .. "/" .. key)
    end
  end
  print("done: " .. count .. " file(s) written to " .. outdir .. "/")
end

----------------------------------------------------------------------
-- dispatch
----------------------------------------------------------------------

local mode = arg[1]
if mode == "send" then
  cmd_send(arg[2])
elseif mode == "get" then
  cmd_get(arg[2], arg[3])
else
  die("usage:\n" ..
      "  translation_job.lua send <to_translate_dir>\n" ..
      "  translation_job.lua get  <batch.txt> <out_dir>")
end
