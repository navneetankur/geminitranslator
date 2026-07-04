#!/usr/bin/env lua
-- translation_job.lua — translate Chinese webnovel chapters via Gemini batch API
--
-- Usage:
--   translation_job.lua send   <to_translate_dir>    -> upload + submit a batch, id to batch.txt
--   translation_job.lua resume <resume.txt>          -> submit a batch from an already-uploaded file
--   translation_job.lua get    <batch.txt> <out_dir> -> if done, download + write translations
--   translation_job.lua status [batch.txt|id ...]    -> report batch state(s); no args = list all
--   translation_job.lua quick  <in.txt> [out.txt]    -> translate one chapter now (no batch)
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

-- find the prompt: <dir>/prompt.txt, else the global config prompt
local function resolve_prompt(dir)
  local p = dir .. "/prompt.txt"
  if not file_exists(p) then
    p = (os.getenv("HOME") or "") .. "/.config/geminitran/prompt.txt"
  end
  if not file_exists(p) then
    die("no prompt at " .. dir .. "/prompt.txt or ~/.config/geminitran/prompt.txt")
  end
  return p
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

-- create a batch pointing at an already-uploaded file handle (the cheap
-- commit). Returns the batch/operation name (or "") and the raw response.
local function create_batch(fname)
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
  return sh("printf %s " .. q(resp) .. " | jq -r '.name // empty'"), resp
end

-- list batches and return the name of one whose input file == `fname`, else "".
-- Lets us detect a batch that was actually created even though its create
-- response was lost (so we never recorded the name). NOTE: only scans the
-- first page (pageSize=100); a just-created batch is expected to be there.
local function find_batch_by_input(fname)
  local resp = sh(table.concat({
    "curl -sS", q(API .. "/batches?pageSize=100"),
    "-H " .. q("x-goog-api-key: " .. KEY),
  }, " "))
  -- the array field is documented only as a ListOperationsResponse; accept either name
  local filter = "(.operations // .batches // [])[] " ..
                 "| select(.metadata.inputConfig.fileName == $f) | .name"
  return sh("printf %s " .. q(resp) .. " | jq -r --arg f " .. q(fname) ..
            " " .. q(filter) .. " | head -n1")
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
  -- guard against re-uploading when a prior upload was never submitted
  if file_exists(F_RESUME) and read_file(F_RESUME):gsub("%s+", "") ~= "" then
    die(F_RESUME .. " exists — a prior upload was not submitted.\n" ..
        "  finish it:     translation_job.lua resume " .. F_RESUME .. "\n" ..
        "  or start over: rm " .. F_RESUME)
  end

  local prompt_path = resolve_prompt(indir)

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
  local batch_name, resp = create_batch(fname)
  if batch_name == "" then
    die("upload succeeded but the batch was not created:\n" .. resp ..
        "\n  the upload is saved — finish with: translation_job.lua resume " .. F_RESUME)
  end

  write_file(F_BATCH, batch_name .. "\n")
  os.remove(F_RESUME) -- committed; clear the pending-upload breadcrumb
  print("batch submitted: " .. batch_name)
  print("wrote id to " .. F_BATCH)
  print("(kept " .. F_JSONL .. " for reference; remove when done: rm " .. F_JSONL .. ")")
end

----------------------------------------------------------------------
-- get
----------------------------------------------------------------------

-- the completed batch points at its output file here (confirmed against a real run)
local OUTFILE = ".response.responsesFile // empty"

-- per-line filter over the downloaded results JSONL -> key<TAB>status<TAB>reason<TAB>b64(text).
-- status is one of:
--   ok        - a candidate finished with STOP; text is complete
--   truncated - a candidate exists but stopped early (MAX_TOKENS etc.); text is partial
--   failed    - no candidate at all (error line or unrecognized shape); no text
local RESULT_LINE = [[
  (.response.candidates[0]) as $c
  | { key:    .key,
      status: ( if $c == null then "failed"
                elif $c.finishReason == "STOP" then "ok"
                else "truncated" end ),
      reason: ( if $c == null then (.response.error.message // "no-candidate")
                else ($c.finishReason // "unknown") end ),
      text:   ( [ $c.content.parts[]?.text ] | join("") ) }
  | "\(.key)\t\(.status)\t\(.reason)\t\(.text | @base64)"
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

  local wrote, truncated, failed = 0, 0, 0
  for line in rows:gmatch("[^\n]+") do
    local key, status, reason, b64 = line:match("^([^\t]*)\t([^\t]*)\t([^\t]*)\t(.*)$")
    if key and key ~= "" then
      local text = sh("printf %s " .. q(b64) .. " | base64 -d")
      local path = outdir .. "/" .. key
      if status == "ok" then
        write_file(path, text)
        wrote = wrote + 1
      elseif status == "truncated" then
        -- keep whatever partial text came back, but mark it clearly
        write_file(path, text .. "\n\nThis file truncated. (" .. reason .. ")\n")
        print("  TRUNCATED " .. key .. " (" .. reason .. ") — wrote partial; re-run this chapter")
        truncated = truncated + 1
      else -- failed
        write_file(path, "This file failed. (" .. reason .. ")\n")
        print("  FAILED " .. key .. " (" .. reason .. ") — re-run this chapter")
        failed = failed + 1
      end
    end
  end

  print("done: " .. wrote .. " ok, " .. truncated .. " truncated, " .. failed ..
        " failed — written to " .. outdir .. "/")
  print("(kept " .. F_RESULTS .. " and " .. F_RAW ..
        "; remove when done: rm " .. F_RESULTS .. " " .. F_RAW .. ")")
end

----------------------------------------------------------------------
-- resume — submit a batch from an already-uploaded file (recover a send
-- that uploaded but failed/was interrupted before creating the batch)
----------------------------------------------------------------------

local function cmd_resume(resumefile)
  resumefile = resumefile or F_RESUME
  if not KEY then die("no API key") end
  if not file_exists(resumefile) then die("no such file: " .. resumefile) end

  if file_exists(F_BATCH) and read_file(F_BATCH):gsub("%s+", "") ~= "" then
    die(F_BATCH .. " already exists (" .. read_file(F_BATCH):gsub("%s+", "") ..
        "); nothing to resume.")
  end

  local fname = read_file(resumefile):gsub("%s+", "")
  if fname == "" then die("no file handle in " .. resumefile) end

  -- guard against a duplicate: the earlier create may have actually
  -- succeeded even though its response was lost. If a batch already
  -- references this upload, adopt it instead of creating a second one.
  print("checking whether a batch already used this upload ...")
  local existing = find_batch_by_input(fname)
  if existing ~= "" then
    write_file(F_BATCH, existing .. "\n")
    os.remove(resumefile)
    print("a batch already exists for this upload (earlier submit had succeeded): " .. existing)
    print("wrote id to " .. F_BATCH)
    return
  end

  print("resuming from " .. fname .. " ...")
  local batch_name, resp = create_batch(fname)
  if batch_name == "" then die("batch still not created:\n" .. resp) end

  write_file(F_BATCH, batch_name .. "\n")
  os.remove(resumefile)
  print("batch submitted: " .. batch_name)
  print("wrote id to " .. F_BATCH)
end

----------------------------------------------------------------------
-- quick — synchronous single-chapter translation (no batch, immediate)
----------------------------------------------------------------------

local function cmd_quick(infile, outfile)
  if not infile then die("usage: translation_job.lua quick <in.txt> [out.txt]") end
  if not KEY then die("no API key") end
  if not file_exists(infile) then die("no such file: " .. infile) end

  local dir = infile:match("^(.*)/[^/]*$") or "."
  local prompt_path = resolve_prompt(dir)

  local payload = os.tmpname()
  sh("jq -n --rawfile prompt " .. q(prompt_path) .. " --rawfile body " .. q(infile) ..
     " '{contents:[{parts:[{text:($prompt + \"\\n\\n\" + $body)}]}]}' > " .. q(payload))

  local respfile = os.tmpname()
  sh(table.concat({
    "curl -sS -X POST", q(API .. "/models/" .. MODEL .. ":generateContent"),
    "-H " .. q("x-goog-api-key: " .. KEY),
    "-H " .. q("Content-Type: application/json"),
    "-d @" .. q(payload),
    "-o " .. q(respfile),
  }, " "))
  os.remove(payload)

  local err = sh("jq -r '.error.message // empty' " .. q(respfile))
  if err ~= "" then os.remove(respfile); die("API error: " .. err) end

  local finish = sh("jq -r '.candidates[0].finishReason // \"\"' " .. q(respfile))
  local text   = sh("jq -r '[ .candidates[0].content.parts[]?.text ] | join(\"\")' " .. q(respfile))
  os.remove(respfile)

  if text == "" then die("no translation returned (finishReason=" .. finish .. ")") end
  if finish ~= "STOP" and finish ~= "" then
    io.stderr:write("warning: finishReason=" .. finish .. " (translation may be truncated)\n")
  end

  if outfile then
    write_file(outfile, text .. "\n")
    print("wrote " .. outfile .. " (finishReason=" .. finish .. ")")
  else
    io.write(text, "\n")
  end
end

----------------------------------------------------------------------
-- status — report batch state(s); no args lists every batch.
-- Exits 0 if ANY batch has finished (SUCCEEDED/DONE), else 1, so it
-- composes in shells: translation_job.lua status batch.txt && echo ready
----------------------------------------------------------------------

-- three fields from a single operation (a GET-by-name response)
local STATUS3 = '[ (.metadata.state // .state // "UNKNOWN"),' ..
  ' (.metadata.batchStats.successfulRequestCount // 0),' ..
  ' (.metadata.batchStats.requestCount // 0) ] | @tsv'
-- name + those three, per operation in a list response
local STATUS_LIST = '(.operations // .batches // [])[] | [ .name,' ..
  ' (.metadata.state // .state // "UNKNOWN"),' ..
  ' (.metadata.batchStats.successfulRequestCount // 0),' ..
  ' (.metadata.batchStats.requestCount // 0) ] | @tsv'

local function cmd_status(names)
  if not KEY then die("no API key") end

  local any_done = false
  local function report(label, state, succ, total)
    state = (state and state ~= "") and state or "UNKNOWN"
    print(string.format("%-46s %-24s %s/%s", label, state, succ or "0", total or "0"))
    if state:match("SUCCEEDED") or state == "DONE" then any_done = true end
  end

  print(string.format("%-46s %-24s %s", "BATCH", "STATE", "DONE/TOTAL"))

  if #names == 0 then
    -- list every batch
    local resp = sh(table.concat({
      "curl -sS", q(API .. "/batches?pageSize=100"),
      "-H " .. q("x-goog-api-key: " .. KEY),
    }, " "))
    local tmp = os.tmpname(); write_file(tmp, resp)
    local out = sh("jq -r " .. q(STATUS_LIST) .. " " .. q(tmp))
    os.remove(tmp)
    for line in out:gmatch("[^\n]+") do
      local name, st, su, to = line:match("^([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)$")
      report(name or "?", st, su, to)
    end
  else
    -- check the specific batches given (id, or a file holding one)
    for _, arg in ipairs(names) do
      local name = arg
      if file_exists(arg) then name = read_file(arg):gsub("%s+", "") end
      local resp = sh(table.concat({
        "curl -sS", q(API .. "/" .. name),
        "-H " .. q("x-goog-api-key: " .. KEY),
      }, " "))
      local row = sh("printf %s " .. q(resp) .. " | jq -r " .. q(STATUS3))
      local st, su, to = row:match("^([^\t]*)\t([^\t]*)\t([^\t]*)$")
      report(arg, st, su, to)
    end
  end

  os.exit(any_done and 0 or 1)
end

----------------------------------------------------------------------
-- dispatch
----------------------------------------------------------------------

local mode = arg[1]
if mode == "send" then
  cmd_send(arg[2])
elseif mode == "resume" then
  cmd_resume(arg[2])
elseif mode == "get" then
  cmd_get(arg[2], arg[3])
elseif mode == "status" then
  local names = {}
  for i = 2, #arg do names[#names + 1] = arg[i] end
  cmd_status(names)
elseif mode == "quick" then
  cmd_quick(arg[2], arg[3])
else
  die("usage:\n" ..
      "  translation_job.lua send   <to_translate_dir>\n" ..
      "  translation_job.lua resume <resume.txt>\n" ..
      "  translation_job.lua get    <batch.txt> <out_dir>\n" ..
      "  translation_job.lua status [batch.txt|id ...]\n" ..
      "  translation_job.lua quick  <in.txt> [out.txt]")
end
