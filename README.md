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
