---
description: Resume the work timer — end the current away interval
---

The human is back. Close the open away interval.

1. Read the **8-char session prefix** from the most recent `[turn-ts HH:MM:SS <epoch> | session <sid_8> | elapsed …]` marker in this turn (the same prefix you pass to `worklog-split.sh`). Never guess or reuse a prefix from earlier in the transcript.
2. Run, as a single bare command (one Bash tool call, no prefix, no chaining):

   `.claude/bin/away.sh end <sid_8>`

3. Relay the script's confirmation line verbatim (it reports this interval + cumulative away). Then resume wherever you left off before the break.
