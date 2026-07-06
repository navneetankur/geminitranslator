#!/usr/bin/env lua
-- translation_job.lua — translate Chinese webnovel chapters via Gemini batch API
--
-- Usage:
--   translation_job.lua send   <to_translate_dir>    -> upload + submit a batch, id to batch.txt
--   translation_job.lua resume <resume.txt>          -> submit a batch from an already-uploaded file
--   translation_job.lua get    <batch.txt> <out_dir> -> if done, download + write translations
--   translation_job.lua status [batch.txt|id ...]    -> report batch state(s); no args = list all
--   translation_job.lua stop   <batch.txt|id>        -> cancel a running batch
--   translation_job.lua delete-file <files/xxx>      -> delete an uploaded input file from the Files API
--   translation_job.lua delete-job  <batch.txt|id>   -> delete the batch job (and its output file)
--   translation_job.lua quick  <in.txt> [out.txt]    -> translate one chapter now (no batch)
--
-- Flags (send, quick):
--   --prompt <file>   file supplying the system-instruction text; repeat to
--                     concat. Overrides the prompt.txt /
--                     ~/.config/geminitran/prompt.txt lookup.
--   --prefix <file>   file prepended to each chapter's body (the user text, not
--                     the prompt); repeat to concat. Overrides the prefix.txt /
--                     ~/.config/geminitran/prefix.txt lookup (which is required
--                     — make it an empty file to no-op the prefix).
--   --thinking <n>    thinking-token budget: 0 = off (default), -1 = auto (let
--                     the model decide), or a positive token budget.
--   --include-thoughts  ask the API to return the model's thinking summary
--                     (includeThoughts=true). Only meaningful with --thinking
--                     != 0. The thoughts stay in the raw result JSON for
--                     inspection; they are stripped from the written
--                     translation so they never pollute the output.
--   --dry-run         (send only) assemble batch_input.jsonl.dryrun and stop —
--                     no upload, no batch; inspect it before a real send.
--   --retry           (quick only) on HTTP 503 (model overloaded), resend with
--                     exponential backoff up to a few attempts instead of dying.
--
-- File-based batch flow (robust retries): build a JSONL, upload it to the
-- Files API (the flaky, retryable step), then create the batch pointing at
-- the uploaded file (the cheap commit). See notes/overview.md.
--
-- Requires: curl, jq, file(1). API key is read from the dofile below.

-- local MODEL    = "gemini-3.1-flash-lite"
-- local MODEL    = "gemini-2.5-flash"
local MODEL    = "gemini-2.5-flash-lite"
local API      = "https://generativelanguage.googleapis.com/v1beta"
local UPLOAD   = "https://generativelanguage.googleapis.com/upload/v1beta/files"
local DOWNLOAD = "https://generativelanguage.googleapis.com/download/v1beta"
local KEY      = dofile(os.getenv("HOME").."/.config/geminitran/toktok.txt")

-- generation knobs, shared by `send` (batch) and `quick` so both produce the
-- same output. low temperature = faithful, consistent translation; thinking
-- disabled by default (flash-lite default, pinned so a default flip won't
-- surprise us) but bumpable per-run with --thinking <budget>. include_thoughts
-- (--include-thoughts) adds includeThoughts:true so the response carries the
-- thinking summary; only useful when thinking != 0.
local function gen_config(thinking, include_thoughts)
  local thoughts = include_thoughts and ", includeThoughts:true" or ""
  return string.format(
    '{temperature:0.3, thinkingConfig:{thinkingBudget:%d%s}}',
    thinking or 0, thoughts)
end

-- files we intentionally keep on disk (for debugging / resume)
local F_JSONL   = "batch_input.jsonl"   -- the request payload we upload
local F_RESUME  = "resume.txt"          -- uploaded file handle (breadcrumb)
local F_BATCH   = "batch.txt"           -- submitted batch/operation name
local F_RAW     = "batch_result.json"   -- raw GET response from `get`
local F_RESULTS = "batch_results.jsonl" -- downloaded results file
-- `quick`'s kept debug files are named per-input (quick_<base>.request/result.json)
-- so parallel runs on different chapters don't clobber each other; see cmd_quick.

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

-- list *.txt files in dir (excluding prompt.txt/prefix.txt), sorted numerically then by name
local function list_inputs(dir)
  local out = sh("ls -1 " .. q(dir) .. " 2>/dev/null")
  local files = {}
  for name in out:gmatch("[^\n]+") do
    if name:match("%.txt$") and name ~= "prompt.txt" and name ~= "prefix.txt" then
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

-- find the prefix, using the same search path as the prompt:
-- <dir>/prefix.txt, else the global config prefix. Required like the prompt —
-- a missing file is an error; make it an empty file to no-op the prefix.
local function resolve_prefix(dir)
  local p = dir .. "/prefix.txt"
  if not file_exists(p) then
    p = (os.getenv("HOME") or "") .. "/.config/geminitran/prefix.txt"
  end
  if not file_exists(p) then
    die("no prefix at " .. dir .. "/prefix.txt or ~/.config/geminitran/prefix.txt")
  end
  return p
end

-- pick the system-instruction prompt file. If any --prompt flags were given,
-- each names a file; their contents are joined with a newline into a temp file
-- (the newline keeps files that lack a trailing one from running together) so
-- the rest of the pipeline can keep passing a path to jq's --rawfile. Returns
-- the path and a boolean saying whether it's a temp file the caller os.removes.
local function build_prompt_path(dir, prompts)
  if prompts and #prompts > 0 then
    local tmp = os.tmpname()
    local parts = {}
    for _, p in ipairs(prompts) do
      if not file_exists(p) then die("no such --prompt file: " .. p) end
      parts[#parts + 1] = read_file(p)
    end
    write_file(tmp, table.concat(parts, "\n"))
    return tmp, true
  end
  return resolve_prompt(dir), false
end

-- join the --prefix files with a newline into a temp file whose contents are
-- prepended to each chapter's body (part of the user text, not the system
-- instruction). A trailing newline is added so the prefix doesn't run into the
-- body in ($prefix + $body). When no --prefix flag is given, falls back to the
-- prefix.txt / ~/.config/geminitran/prefix.txt lookup (resolve_prefix), which
-- is required — make it an empty file to no-op the prefix. Always returns a
-- temp path the caller must os.remove.
local function build_prefix_path(dir, prefixes)
  local tmp = os.tmpname()
  local parts = {}
  if prefixes and #prefixes > 0 then
    for _, p in ipairs(prefixes) do
      if not file_exists(p) then die("no such --prefix file: " .. p) end
      parts[#parts + 1] = read_file(p)
    end
  else
    parts[#parts + 1] = read_file(resolve_prefix(dir))
  end
  -- add the body-separating newline only when there's actual prefix text, so an
  -- empty prefix.txt is a true no-op (no stray leading blank line on each body).
  local text = table.concat(parts, "\n")
  write_file(tmp, text ~= "" and (text .. "\n") or "")
  return tmp
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
  -- list responses wrap the batches in .operations (// [] guards an empty list)
  local filter = "(.operations // [])[] " ..
                 "| select(.metadata.inputConfig.fileName == $f) | .name"
  return sh("printf %s " .. q(resp) .. " | jq -r --arg f " .. q(fname) ..
            " " .. q(filter) .. " | head -n1")
end

----------------------------------------------------------------------
-- send
----------------------------------------------------------------------

local function cmd_send(indir, prompts, prefixes, dryrun, thinking, include_thoughts)
  if not indir then die("usage: translation_job.lua send <dir>") end
  indir = indir:gsub("/+$", "")

  -- a dry run only assembles the JSONL to eyeball it; it uploads nothing and
  -- creates no batch, so it needs neither the API key nor the double-submit
  -- guards (which would otherwise block previewing while a batch is pending).
  if not dryrun then
    if not KEY then die("no API key") end

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
  end

  local prompt_path, prompt_tmp = build_prompt_path(indir, prompts)
  local prefix_path = build_prefix_path(indir, prefixes)

  local files = list_inputs(indir)
  if #files == 0 then die("no *.txt files to translate in " .. indir) end

  -- a dry run writes to a side file so it never clobbers the real F_JSONL that
  -- an in-flight batch was built from.
  local jsonl = dryrun and (F_JSONL .. ".dryrun") or F_JSONL

  -- build the JSONL: one {"key","request"} line per chapter (jq handles escaping)
  local out = assert(io.open(jsonl, "w"))
  for _, name in ipairs(files) do
    local line = sh(table.concat({
      "jq -c",
      "--arg key " .. q(name),
      "--rawfile prompt " .. q(prompt_path),
      "--rawfile prefix " .. q(prefix_path),
      "--rawfile body " .. q(indir .. "/" .. name),
      "-n " .. q('{key:$key, request:{system_instruction:{parts:[{text:$prompt}]}, contents:[{parts:[{text:($prefix + $body)}]}], generationConfig:' .. gen_config(thinking, include_thoughts) .. '}}'),
    }, " "))
    out:write(line, "\n")
  end
  out:close()
  if prompt_tmp then os.remove(prompt_path) end
  os.remove(prefix_path)
  print("built " .. jsonl .. " (" .. #files .. " chapter(s))")

  if dryrun then
    print("dry run — nothing uploaded, no batch created.")
    print("inspect the assembled requests:  jq . " .. jsonl)
    return
  end

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
      text:   ( [ $c.content.parts[]? | select(.thought != true) | .text ] | join("") ) }
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
        write_file(path, text .. "\n")
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
  if truncated == 0 and failed == 0 then
    -- clean run: nothing left to re-do, so all the batch artifacts are junk
    local junk = {}
    for _, f in ipairs({ F_RESULTS, F_RAW, F_JSONL, batchfile }) do
      if file_exists(f) then junk[#junk + 1] = f end
    end
    print("all ok — clean up when done:  rm " .. table.concat(junk, " "))
  else
    -- keep everything: re-running the bad chapters needs these
    print("(kept " .. F_RESULTS .. " and " .. F_RAW ..
          " for re-runs; don't delete until every chapter is ok)")
  end
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

local function cmd_quick(infile, outfile, prompts, prefixes, thinking, retry, include_thoughts)
  if not infile then die("usage: translation_job.lua quick <in.txt> [out.txt]") end
  if not KEY then die("no API key") end
  if not file_exists(infile) then die("no such file: " .. infile) end

  local dir = infile:match("^(.*)/[^/]*$") or "."
  local prompt_path, prompt_tmp = build_prompt_path(dir, prompts)
  local prefix_path = build_prefix_path(dir, prefixes)

  -- name the kept debug files after the input (12.txt -> quick_12.request.json)
  -- so two `quick` runs on different chapters don't overwrite each other's files.
  local base = (infile:match("([^/]+)$") or infile):gsub("%.txt$", "")
  local F_QUICK_REQ = "quick_" .. base .. ".request.json"
  local F_QUICK_RAW = "quick_" .. base .. ".result.json"

  -- both files are kept (success or failure) for debugging; remind to clean up.
  -- to stderr so it never lands in stdout when the translation is piped from it.
  local function remind()
    io.stderr:write("(kept " .. F_QUICK_REQ .. " and " .. F_QUICK_RAW ..
      " for debugging; remove when done: rm " .. F_QUICK_REQ .. " " .. F_QUICK_RAW .. ")\n")
  end

  local payload = F_QUICK_REQ
  sh("jq -n --rawfile prompt " .. q(prompt_path) .. " --rawfile prefix " .. q(prefix_path) ..
     " --rawfile body " .. q(infile) ..
     " " .. q('{system_instruction:{parts:[{text:$prompt}]}, contents:[{parts:[{text:($prefix + $body)}]}], generationConfig:' .. gen_config(thinking, include_thoughts) .. '}') ..
     " > " .. q(payload))
  if prompt_tmp then os.remove(prompt_path) end
  os.remove(prefix_path)

  local respfile = F_QUICK_RAW
  local curl = table.concat({
    "curl -sS -X POST", q(API .. "/models/" .. MODEL .. ":generateContent"),
    "-H " .. q("x-goog-api-key: " .. KEY),
    "-H " .. q("Content-Type: application/json"),
    "-d @" .. q(payload),
    "-o " .. q(respfile),
  }, " ")

  -- 503 = "model overloaded, try again later" — transient. With --retry, resend
  -- last response is left in respfile so the error path below reports it normally.
  local MAX_ATTEMPTS = 1000
  local attempt = 1
  while true do
    sh(curl)
    local code = sh("jq -r '.error.code // empty' " .. q(respfile))
    if code ~= "503" or not retry or attempt >= MAX_ATTEMPTS then break end
	io.stderr:write(string.format("503 (model overloaded); retrying in %ds\n", 4))
    os.execute("sleep 4")
    attempt = attempt + 1
  end

  local err = sh("jq -r '.error.message // empty' " .. q(respfile))
  if err ~= "" then remind(); die("API error: " .. err) end

  local finish = sh("jq -r '.candidates[0].finishReason // \"\"' " .. q(respfile))
  local text   = sh("jq -r '[ .candidates[0].content.parts[]? | select(.thought != true) | .text ] | join(\"\")' " .. q(respfile))

  if text == "" then remind(); die("no translation returned (finishReason=" .. finish .. ")") end
  if finish ~= "STOP" and finish ~= "" then
    io.stderr:write("warning: finishReason=" .. finish .. " (translation may be truncated)\n")
  end

  if outfile then
    write_file(outfile, text .. "\n")
    print("wrote " .. outfile .. " (finishReason=" .. finish .. ")")
  else
    io.write(text, "\n")
  end
  remind()
end

----------------------------------------------------------------------
-- status — report batch state(s); no args lists every batch.
-- Exits 0 if ANY batch has finished (SUCCEEDED/DONE), else 1, so it
-- composes in shells: translation_job.lua status batch.txt && echo ready
----------------------------------------------------------------------

-- fields from a single operation (a GET-by-name response). responsesFile is
-- the output file; it only appears once the batch has finished.
local STATUS3 = '[ (.metadata.state // .state // "UNKNOWN"),' ..
  ' (.metadata.batchStats.successfulRequestCount // 0),' ..
  ' (.metadata.batchStats.requestCount // 0),' ..
  ' (.metadata.inputConfig.fileName // "-"),' ..
  ' (.response.responsesFile // "-") ] | @tsv'
-- name + those fields, per operation in a list response
local STATUS_LIST = '(.operations // [])[] | [ .name,' ..
  ' (.metadata.state // .state // "UNKNOWN"),' ..
  ' (.metadata.batchStats.successfulRequestCount // 0),' ..
  ' (.metadata.batchStats.requestCount // 0),' ..
  ' (.metadata.inputConfig.fileName // "-"),' ..
  ' (.response.responsesFile // "-") ] | @tsv'

local function cmd_status(names)
  if not KEY then die("no API key") end

  local any_done = false
  local finished = {} -- {label, input, output} per SUCCEEDED batch, for the delete reminder
  local function report(label, state, succ, total, file, outfile)
    state = (state and state ~= "") and state or "UNKNOWN"
    print(string.format("%-46s %-24s %-9s %-50s %s",
      label, state, (succ or "0") .. "/" .. (total or "0"), file or "-", outfile or "-"))
    if state:match("SUCCEEDED") or state == "DONE" then
      any_done = true
      finished[#finished + 1] = { label = label, input = file, output = outfile }
    end
  end

  print(string.format("%-46s %-24s %-9s %-50s %s", "BATCH", "STATE", "DONE/TOT", "INPUT", "OUTPUT"))

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
      local name, st, su, to, fn, of = line:match("^([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)$")
      report(name or "?", st, su, to, fn, of)
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
      local st, su, to, fn, of = row:match("^([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)$")
      report(arg, st, su, to, fn, of)
    end
  end

  -- the file's own expirationTime reads null, but the parent batch hard-expires
  -- ~48h after it finishes and GC takes the output file down with it. So the
  -- real deadline is: run `get` within 48h. Deleting by hand is optional and
  -- only frees Files-API quota sooner.
  local self = arg[0] or "translation_job.lua"
  for _, b in ipairs(finished) do
    local has_out = b.output and b.output ~= "-" and b.output ~= ""
    local has_in  = b.input  and b.input  ~= "-" and b.input  ~= ""
    if has_out or has_in then
      print("")
      print("finished " .. b.label .. " — run `get` within ~48h (the batch and its " ..
            "output are auto-purged after that). free quota sooner with:")
      if has_out then
        print("  " .. self .. " delete-job " .. b.label ..
              "   # removes the batch + its output file (after `get`)")
      end
      if has_in then
        print("  " .. self .. " delete-file " .. b.input ..
              "   # the uploaded input; delete-job does NOT remove it")
      end
    end
  end

  os.exit(any_done and 0 or 1)
end

----------------------------------------------------------------------
-- stop — cancel a running batch. The batch keeps its name and moves to a
-- CANCELLED state; check with `status`. Takes a batch id or a file holding one.
----------------------------------------------------------------------

local function cmd_stop(arg1)
  if not arg1 then die("usage: translation_job.lua stop <batch.txt|id>") end
  if not KEY then die("no API key") end

  local name = arg1
  if file_exists(arg1) then name = read_file(arg1):gsub("%s+", "") end
  if name == "" then die("empty batch id in " .. arg1) end

  local resp = sh(table.concat({
    "curl -sS -X POST", q(API .. "/" .. name .. ":cancel"),
    "-H " .. q("x-goog-api-key: " .. KEY),
    "-H " .. q("Content-Type: application/json"),
  }, " "))

  local err = sh("printf %s " .. q(resp) .. " | jq -r '.error.message // empty'")
  if err ~= "" then die("cancel failed: " .. err) end

  print("cancel requested for " .. name)
  print("(verify with: translation_job.lua status " .. arg1 .. ")")
end

----------------------------------------------------------------------
-- delete-file — delete a file from the Files API by its files/xxx handle.
-- Used for the uploaded input file. NOTE: it can't delete a batch's output
-- file — those names (batch-<id>) exceed the API's 40-char id limit; the way
-- to drop the output is `delete-job` (or the 48h auto-purge).
----------------------------------------------------------------------

local function cmd_delete_file(name)
  if not name then die("usage: translation_job.lua delete-file <files/xxx>") end
  if not KEY then die("no API key") end
  name = name:gsub("%s+", "")
  if name == "" then die("empty file name") end

  local resp = sh(table.concat({
    "curl -sS -X DELETE", q(API .. "/" .. name),
    "-H " .. q("x-goog-api-key: " .. KEY),
  }, " "))

  local err = sh("printf %s " .. q(resp) .. " | jq -r '.error.message // empty'")
  if err ~= "" then die("delete failed: " .. err) end

  print("deleted " .. name)
end

----------------------------------------------------------------------
-- delete-job — delete the batch resource itself. This also removes the batch's
-- generated output file, but NOT the uploaded input file (that's a separate
-- resource — drop it with `delete-file`). Takes a batch id or a file holding
-- one (same convention as `stop`/`status`).
----------------------------------------------------------------------

local function cmd_delete_job(arg1)
  if not arg1 then die("usage: translation_job.lua delete-job <batch.txt|id>") end
  if not KEY then die("no API key") end

  local name = arg1
  if file_exists(arg1) then name = read_file(arg1):gsub("%s+", "") end
  if name == "" then die("empty batch id in " .. arg1) end

  local resp = sh(table.concat({
    "curl -sS -X DELETE", q(API .. "/" .. name),
    "-H " .. q("x-goog-api-key: " .. KEY),
  }, " "))

  local err = sh("printf %s " .. q(resp) .. " | jq -r '.error.message // empty'")
  if err ~= "" then die("delete failed: " .. err) end

  print("deleted batch job " .. name)
end

----------------------------------------------------------------------
-- dispatch
----------------------------------------------------------------------

-- pull flags out of argv, leaving the positional args. --prompt names a file
-- supplying the system-instruction text (repeat to concat), overriding the
-- prompt.txt lookup. --prefix names a file whose contents are prepended to each
-- chapter's body (repeat to concat). --dry-run makes `send` assemble the JSONL
-- and stop (no upload, no batch). --thinking <budget> sets the model's thinking
-- token budget (default 0 = off). --include-thoughts returns the thinking
-- summary in the response. All apply only to send/quick.
local function parse_flags(argv)
  local pos, prompts, prefixes, dryrun, thinking, retry, include_thoughts =
    {}, {}, {}, false, nil, false, false
  local i = 1
  while i <= #argv do
    local a = argv[i]
    if a == "--prompt" then
      i = i + 1
      if not argv[i] then die("--prompt needs a file") end
      prompts[#prompts + 1] = argv[i]
    elseif a == "--prefix" then
      i = i + 1
      if not argv[i] then die("--prefix needs a file") end
      prefixes[#prefixes + 1] = argv[i]
    elseif a == "--dry-run" then
      dryrun = true
    elseif a == "--retry" then
      retry = true
    elseif a == "--include-thoughts" then
      include_thoughts = true
    elseif a == "--thinking" then
      i = i + 1
      thinking = tonumber(argv[i])
      if not thinking or thinking < -1 or thinking ~= math.floor(thinking) then
        die("--thinking needs a token budget: -1 (auto), 0 (off), or a positive integer")
      end
    else
      pos[#pos + 1] = a
    end
    i = i + 1
  end
  return pos, prompts, prefixes, dryrun, thinking, retry, include_thoughts
end

local mode = arg[1]
local argv = {}
for i = 2, #arg do argv[#argv + 1] = arg[i] end
local pos, prompts, prefixes, dryrun, thinking, retry, include_thoughts = parse_flags(argv)

if mode == "send" then
  cmd_send(pos[1], prompts, prefixes, dryrun, thinking, include_thoughts)
elseif mode == "resume" then
  cmd_resume(pos[1])
elseif mode == "get" then
  cmd_get(pos[1], pos[2])
elseif mode == "status" then
  cmd_status(pos)
elseif mode == "stop" then
  cmd_stop(pos[1])
elseif mode == "delete-file" then
  cmd_delete_file(pos[1])
elseif mode == "delete-job" then
  cmd_delete_job(pos[1])
elseif mode == "quick" then
  cmd_quick(pos[1], pos[2], prompts, prefixes, thinking, retry, include_thoughts)
else
  die("usage:\n" ..
      "  translation_job.lua send   <to_translate_dir>\n" ..
      "  translation_job.lua resume <resume.txt>\n" ..
      "  translation_job.lua get    <batch.txt> <out_dir>\n" ..
      "  translation_job.lua status [batch.txt|id ...]\n" ..
      "  translation_job.lua stop   <batch.txt|id>\n" ..
      "  translation_job.lua delete-file <files/xxx>\n" ..
      "  translation_job.lua delete-job  <batch.txt|id>\n" ..
      "  translation_job.lua quick  <in.txt> [out.txt]")
end
