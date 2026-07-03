---
description: Pause the work timer for an away interval (meal break / meeting)
---

The human is stepping away. Record the start of an away interval so the break is excluded from the Human/AI split.

1. Read the **8-char session prefix** from the most recent `[turn-ts HH:MM:SS <epoch> | session <sid_8> | elapsed …]` marker in this turn (the same prefix you pass to `worklog-split.sh`). Never guess or reuse a prefix from earlier in the transcript.
2. Run, as a single bare command (one Bash tool call, no prefix, no chaining):

   `.claude/bin/away.sh start <sid_8>`

3. Relay the script's confirmation line verbatim and wait. Do not start new work until the human sends `/bk`.
