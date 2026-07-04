# translation_job.lua

A simple lua + curl + jq tool to translate Chinese webnovels with the
Gemini API (`gemini-2.5-flash-lite`).

- **API key**: read from `~/.config/geminitran/toktok.txt` (a lua file that
  returns the key string).
- **Prompt**: `<dir>/prompt.txt` if present, else `~/.config/geminitran/prompt.txt`.
- Chapters are plain text files named `1.txt`, `2.txt`, … (processed in
  numeric order). `prompt.txt` in the input dir is not treated as a chapter.

## Subcommands

```
translation_job.lua send   <to_translate_dir>    upload + submit a batch, id -> batch.txt
translation_job.lua resume <resume.txt>          submit a batch from an already-uploaded file
translation_job.lua get    <batch.txt> <out_dir> if done, download + write translations
translation_job.lua status [batch.txt|id ...]    report batch state(s); no args = list all
translation_job.lua quick  <in.txt> [out.txt]    translate one chapter now (no batch)
```

### send / resume — file-based batch, robust retries

`send` builds a JSONL (one request per chapter, prompt prefixed), then:

1. uploads it to the Files API — the flaky, retryable step; nothing is
   committed yet. The file handle is saved to `resume.txt`.
2. creates the batch pointing at that file — the cheap commit. The batch
   name goes to `batch.txt` and `resume.txt` is removed.

If a `send` is interrupted in the ~5-7s gap between upload and commit,
`resume.txt` survives; `resume` finishes the job without re-uploading.
Before creating, `resume` lists batches and, if one already references the
uploaded file, adopts it instead of submitting a duplicate (covers a lost
create response). `send` refuses to run while a leftover `resume.txt`
exists, and refuses if `batch.txt` already exists.

### get — download results

Polls the batch; when it has succeeded, downloads the results file and
writes one file per chapter into `<out_dir>`, keyed by the original name.
Every chapter produces a file:

- ok            -> the translation
- truncated     -> partial text + `This file truncated. (reason)`  (also warns on stdout)
- failed        -> `This file failed. (reason)`                     (also warns on stdout)

Re-run any truncated/failed chapters. Ends with `N ok, M truncated, K failed`.

### status — check state

`GET /v1beta/batches`. No args lists every batch; args check specific ones
(a batch id, or a file holding one). Exits 0 if any batch is done, else 1,
so it composes: `translation_job.lua status batch.txt && echo ready`.

### quick — synchronous single chapter

Uses the non-batch `generateContent` endpoint for an immediate result when
you don't want to wait on a batch. Writes to the output file, or prints to
stdout if none is given. Warns if the response was truncated.

## Files written at runtime (all gitignored)

| file                  | written by | meaning                                   |
|-----------------------|------------|-------------------------------------------|
| `batch_input.jsonl`   | send       | the uploaded request payload (kept for reference) |
| `resume.txt`          | send       | uploaded file handle; present => not yet submitted |
| `batch.txt`           | send/resume| submitted batch name (the id you poll)    |
| `batch_result.json`   | get        | raw GET response (for debugging)          |
| `batch_results.jsonl` | get        | downloaded results file                   |

## Requirements

`lua`, `curl`, `jq`, `file(1)`, and `base64`.
