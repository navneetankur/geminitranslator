We will create simple script. lua + curl + jq
To translate chinese webnovel

translation_job.lua send to_translate/
This will read files from to_translate/{1,2,3,4..}.txt
And prefix with to_translate/prompt.txt or ~/.config/geminitran/prompt.txt
and then send batch job to gemini-2.5-flash-lite, and write id to batch.txt

translation_job.lua get batch.txt translated/
this will get batch job if completed and put translated file in translated/
