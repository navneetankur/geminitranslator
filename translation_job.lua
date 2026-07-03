#!/usr/bin/env lua
-- translation_job.lua — translate Chinese webnovel chapters via Gemini batch API
--
-- Usage:
--   translation_job.lua send <to_translate_dir>    -> upload + submit a batch, id to batch.txt
--   translation_job.lua get  <batch.txt> <out_dir> -> if done, download + write translations
--
-- File-based batch flow (robust retries): build a JSONL, upload it to the
-- Files API (the flaky, retryable step), then create the batch pointing at
-- the uploaded file (the cheap commit). See notes/overview.md.
--
-- Requires: curl, jq, file(1). API key is read from the dofile below.

local MODEL    = "gemini-2.5-flash-lite"
local API      = "https://generativelanguage.googleapis.com/v1beta"
local UPLOAD   = "https://generativelanguage.googleapis.com/upload/v1beta/files"
local DOWNLOAD = "https://generativelanguage.googleapis.com/download/v1beta"
local KEY      = dofile(os.getenv("HOME").."/.config/geminitran/toktok.txt")

-- files we intentionally keep on disk (for debugging / resume)
local F_JSONL   = "batch_input.jsonl"   -- the request payload we upload
local F_RESUME  = "resume.txt"          -- uploaded file handle (breadcrumb)
local F_BATCH   = "batch.txt"           -- submitted batch/operation name
local F_RAW     = "batch_result.json"   -- raw GET response from `get`
local F_RESULTS = "batch_results.jsonl" -- downloaded results file

----------------------------------------------------------------------
-- small helpers
----------------------------------------------------------------------

local function die(msg)
  io.stderr:write("error: " .. msg .. "\n")
  os.exit(1)
end

-- run a shell command, return stdout (trailing whitespace trimmed)
local function sh(cmd)
  local f = assert(io.popen(cmd, "r"))
  local out = f:read("*a") or ""
  f:close()
  return (out:gsub("%s+$", ""))
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
-- Files API upload (resumable protocol)
----------------------------------------------------------------------

-- upload a local file, return its "files/xxxx" handle. This is the
-- retryable step: nothing is committed until the batch is created.
local function upload_file(path, display)
  local nbytes = sh("wc -c < " .. q(path))
  local mime   = sh("file -b --mime-type " .. q(path)) -- server just wants a plausible type
  local hdr    = os.tmpname()

  -- step 1: start a resumable session; the upload URL comes back in a header
  local start_payload = os.tmpname()
  sh("jq -nc --arg d " .. q(display) .. " '{file:{display_name:$d}}' > " .. q(start_payload))
  sh(table.concat({
    "curl -sS -D " .. q(hdr) .. " -o /dev/null -X POST", q(UPLOAD),
    "-H " .. q("x-goog-api-key: " .. KEY),
    "-H " .. q("X-Goog-Upload-Protocol: resumable"),
    "-H " .. q("X-Goog-Upload-Command: start"),
    "-H " .. q("X-Goog-Upload-Header-Content-Length: " .. nbytes),
    "-H " .. q("X-Goog-Upload-Header-Content-Type: " .. mime),
    "-H " .. q("Content-Type: application/json"),
    "-d @" .. q(start_payload),
  }, " "))
  os.remove(start_payload)

  local upurl = sh("grep -i '^x-goog-upload-url:' " .. q(hdr) ..
                   " | tr -d '\\r' | sed 's/^[^:]*: *//'")
  os.remove(hdr)
  if upurl == "" then
    die("upload did not return an upload URL (check key / network); nothing committed")
  end

  -- step 2: send the bytes and finalize in one shot
  local resp = sh(table.concat({
    "curl -sS", q(upurl),
    "-H " .. q("x-goog-api-key: " .. KEY),
    "-H " .. q("X-Goog-Upload-Offset: 0"),
    "-H " .. q("X-Goog-Upload-Command: upload, finalize"),
    "--data-binary @" .. q(path),
  }, " "))

  local name = sh("printf %s " .. q(resp) .. " | jq -r '.file.name // empty'")
  if name == "" then die("upload finalize returned no file name:\n" .. resp) end
  return name
end

----------------------------------------------------------------------
-- send
----------------------------------------------------------------------

local function cmd_send(indir)
  if not indir then die("usage: translation_job.lua send <dir>") end
  if not KEY then die("no API key") end
  indir = indir:gsub("/+$", "")

  -- guard against accidentally submitting (and paying for) a second batch
  if file_exists(F_BATCH) and read_file(F_BATCH):gsub("%s+", "") ~= "" then
    die(F_BATCH .. " already exists (" .. read_file(F_BATCH):gsub("%s+", "") ..
        "). Delete it to submit a new batch.")
  end

  -- locate prompt file
  local prompt_path = indir .. "/prompt.txt"
  if not file_exists(prompt_path) then
    prompt_path = (os.getenv("HOME") or "") .. "/.config/geminitran/prompt.txt"
  end
  if not file_exists(prompt_path) then
    die("no prompt at " .. indir .. "/prompt.txt or ~/.config/geminitran/prompt.txt")
  end

  local files = list_inputs(indir)
  if #files == 0 then die("no *.txt files to translate in " .. indir) end

  -- build the JSONL: one {"key","request"} line per chapter (jq handles escaping)
  local out = assert(io.open(F_JSONL, "w"))
  for _, name in ipairs(files) do
    local line = sh(table.concat({
      "jq -c",
      "--arg key " .. q(name),
      "--rawfile prompt " .. q(prompt_path),
      "--rawfile body " .. q(indir .. "/" .. name),
      "-n " .. q('{key:$key, request:{contents:[{parts:[{text:($prompt + "\\n\\n" + $body)}]}]}}'),
    }, " "))
    out:write(line, "\n")
  end
  out:close()
  print("built " .. F_JSONL .. " (" .. #files .. " chapter(s))")

  -- upload (retryable; no commit yet)
  print("uploading to Files API ...")
  local fname = upload_file(F_JSONL, "webnovel-batch")
  write_file(F_RESUME, fname .. "\n")
  print("uploaded: " .. fname .. "  (recorded in " .. F_RESUME .. ")")

  -- create the batch pointing at the uploaded file (the cheap commit)
  local payload = os.tmpname()
  sh("jq -nc --arg f " .. q(fname) ..
     " '{batch:{display_name:\"webnovel\", input_config:{file_name:$f}}}' > " .. q(payload))
  local resp = sh(table.concat({
    "curl -sS -X POST", q(API .. "/models/" .. MODEL .. ":batchGenerateContent"),
    "-H " .. q("x-goog-api-key: " .. KEY),
    "-H " .. q("Content-Type: application/json"),
    "-d @" .. q(payload),
  }, " "))
  os.remove(payload)

  local batch_name = sh("printf %s " .. q(resp) .. " | jq -r '.name // empty'")
  if batch_name == "" then die("batch not created:\n" .. resp) end

  write_file(F_BATCH, batch_name .. "\n")
  print("batch submitted: " .. batch_name)
  print("wrote id to " .. F_BATCH)
  print("(kept " .. F_JSONL .. " for reference; remove when done: rm " .. F_JSONL .. ")")
end

----------------------------------------------------------------------
-- get
----------------------------------------------------------------------

-- PROVISIONAL: the docs are vague on where a *file-based* result points to
-- its output file, so we coalesce the likely candidates. If `get` says it
-- succeeded but finds no file, inspect batch_result.json and pin the path.
local OUTFILE = table.concat({
  ".response.responsesFile",
  ".metadata.output.responsesFile",
  ".dest.responsesFile",
  ".dest.fileName",
  ".dest.file_name",
  "empty",
}, " // ")

-- per-line filter over the downloaded results JSONL -> key<TAB>ok<TAB>reason<TAB>b64(text).
-- ok is false for API errors or a truncated/blocked finishReason, so callers
-- can warn+skip instead of writing an empty/partial file.
local RESULT_LINE = [[
  (.response.candidates[0]) as $c
  | { key:    .key,
      ok:     ( ((.response.error // .error) == null)
                and (($c.finishReason // "STOP") == "STOP") ),
      reason: ( $c.finishReason
                // (.response.error.message // .error.message // "no-candidate") ),
      text:   ( [ $c.content.parts[]?.text ] | join("") ) }
  | "\(.key)\t\(.ok)\t\(.reason)\t\(.text | @base64)"
]]

local function cmd_get(batchfile, outdir)
  if not batchfile or not outdir then
    die("usage: translation_job.lua get <batch.txt> <out_dir>")
  end
  if not KEY then die("no API key") end
  outdir = outdir:gsub("/+$", "")

  local batch_name = read_file(batchfile):gsub("%s+", "")
  if batch_name == "" then die("empty batch id in " .. batchfile) end

  local resp = sh(table.concat({
    "curl -sS", q(API .. "/" .. batch_name),
    "-H " .. q("x-goog-api-key: " .. KEY),
  }, " "))
  write_file(F_RAW, resp .. "\n") -- always keep the raw response

  local state = sh("printf %s " .. q(resp) ..
    " | jq -r '.metadata.state // .state // (if .done then \"DONE\" else \"RUNNING\" end) // \"UNKNOWN\"'")
  print("batch state: " .. state)

  if not (state:match("SUCCEEDED") or state == "DONE") then
    if state:match("FAILED") or state:match("CANCELLED") or state:match("EXPIRED") then
      die("batch did not succeed (state=" .. state .. "); see " .. F_RAW)
    end
    print("not finished yet — try again later. (raw saved to " .. F_RAW .. ")")
    return
  end

  local rfile = sh("printf %s " .. q(resp) .. " | jq -r " .. q(OUTFILE))
  if rfile == "" then
    die("succeeded but no results-file field found — inspect " .. F_RAW ..
        " and adjust the OUTFILE paths")
  end

  print("downloading results (" .. rfile .. ") ...")
  sh(table.concat({
    "curl -sS -o " .. q(F_RESULTS),
    q(DOWNLOAD .. "/" .. rfile .. ":download?alt=media"),
    "-H " .. q("x-goog-api-key: " .. KEY),
  }, " "))
  if not file_exists(F_RESULTS) then die("download produced no file") end

  os.execute("mkdir -p " .. q(outdir))

  local rows = sh("jq -rc " .. q(RESULT_LINE) .. " " .. q(F_RESULTS))
  if rows == "" then
    die("results file has no parseable lines — inspect " .. F_RESULTS)
  end

  local wrote, skipped = 0, 0
  for line in rows:gmatch("[^\n]+") do
    local key, ok, reason, b64 = line:match("^([^\t]*)\t([^\t]*)\t([^\t]*)\t(.*)$")
    if key and key ~= "" then
      if ok == "true" then
        local text = sh("printf %s " .. q(b64) .. " | base64 -d")
        write_file(outdir .. "/" .. key, text)
        wrote = wrote + 1
      else
        io.stderr:write("  SKIP " .. key .. " (" .. reason .. ")\n")
        skipped = skipped + 1
      end
    end
  end

  print("done: " .. wrote .. " written to " .. outdir .. "/" ..
        (skipped > 0 and (", " .. skipped .. " skipped — re-run those chapters") or ""))
  print("(kept " .. F_RESULTS .. " and " .. F_RAW ..
        "; remove when done: rm " .. F_RESULTS .. " " .. F_RAW .. ")")
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
