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
local KEY     = dofile(os.getenv("HOME").."/.config/geminitran/toktok.txt")


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

-- The GET returns a long-running Operation; its .response is a
-- GenerateContentBatchOutput whose .inlinedResponses.inlinedResponses[]
-- holds one entry per request. (.metadata.output mirrors the same data,
-- but .response is the operation's canonical result.)
local ITEMS = ".response.inlinedResponses.inlinedResponses[]"

-- One short line per request: key <TAB> error-message <TAB> finishReason.
-- Kept small on purpose so it is safe to read via the shell; the actual
-- (potentially huge) translated text is never put on a command line —
-- it is streamed file -> jq -> file per key below.
local STATUS = ITEMS .. [[
  | [ (.metadata.key // "unknown"),
      (.error.message // .response.error.message // ""),
      (.response.candidates[0].finishReason // "") ]
  | @tsv
]]

-- Extract the full translated text for a single key, straight to stdout.
local TEXT_FOR_KEY = ITEMS .. [[
  | select((.metadata.key // "unknown") == $k)
  | [ .response.candidates[]?.content.parts[]?.text ] | join("")
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

  -- Keep the raw response on disk and run all jq against the FILE. The
  -- response can be many MB, so it must never be passed as a shell
  -- argument (that hits ARG_MAX -> "Argument list too long").
  local RESULT = "batch_result.json"
  write_file(RESULT, resp .. "\n")
  resp = nil  -- don't keep the big blob around; read from the file instead

  local state = sh("jq -r '.metadata.state // .state // " ..
    "(if .done then \"DONE\" else \"RUNNING\" end) // \"UNKNOWN\"' " .. q(RESULT))
  print("batch state: " .. state)

  if not (state:match("SUCCEEDED") or state == "DONE") then
    if state:match("FAILED") or state:match("CANCELLED") or state:match("EXPIRED") then
      die("batch did not succeed (state=" .. state .. "); see " .. RESULT)
    end
    print("not finished yet — try again later. (raw saved to " .. RESULT .. ")")
    return
  end

  os.execute("mkdir -p " .. q(outdir))

  -- small per-item status table: key, error, finishReason
  local status = sh("jq -r " .. q(STATUS) .. " " .. q(RESULT))
  if status == "" then
    die("job succeeded but no responses found — inspect " .. RESULT ..
        " to confirm the JSON path")
  end

  local count, skipped = 0, 0
  for line in status:gmatch("[^\n]+") do
    local key, err, finish = line:match("^([^\t]*)\t([^\t]*)\t([^\t]*)$")
    if not key or key == "" or key == "unknown" then
      io.stderr:write("  ! response with no key — skipped (see " .. RESULT .. ")\n")
      skipped = skipped + 1
    elseif err ~= "" then
      io.stderr:write("  ! " .. key .. ": request failed (" .. err .. ") — skipped\n")
      skipped = skipped + 1
    elseif finish ~= "" and finish ~= "STOP" then
      -- e.g. MAX_TOKENS (truncated) or SAFETY (blocked): don't silently
      -- write partial/empty output as if it were a clean translation.
      io.stderr:write("  ! " .. key .. ": finishReason=" .. finish ..
        " — skipped (not a clean STOP)\n")
      skipped = skipped + 1
    else
      -- stream the text file -> jq -> output file; nothing large on argv
      local out = outdir .. "/" .. key
      local ok = os.execute("jq -j --arg k " .. q(key) .. " " ..
        q(TEXT_FOR_KEY) .. " " .. q(RESULT) .. " > " .. q(out))
      if ok then
        count = count + 1
        print("  wrote " .. out)
      else
        io.stderr:write("  ! " .. key .. ": failed to write output\n")
        skipped = skipped + 1
      end
    end
  end
  print(("done: %d written, %d skipped -> %s/"):format(count, skipped, outdir))
  if skipped > 0 then
    print("re-run those chapters through send/ after checking " .. RESULT)
  end
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
