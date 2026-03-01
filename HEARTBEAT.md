# Heartbeat Checklist

When you wake up for a heartbeat cycle, review this list:

1. **Scheduled tasks** — Check `/workspace/ipc/current_tasks.json`. Any failures or tasks needing attention?
2. **Memory health** — Is your MEMORY.md getting large? Should anything be archived?
3. **Pending items** — Did you promise to follow up on anything? Check recent conversation history.
4. **System health** — Any errors in recent logs? Anything unusual?

## Response Rules

- If nothing needs attention: respond with only `HEARTBEAT_OK` (this is silent — user won't see it)
- If something needs attention: send a brief, actionable message to the user
- Never send a heartbeat message just to say "all good!" — silence means all good

## Memory Flush

Before context compaction, write any important learnings to `MEMORY.md`. Treat this as your last chance to remember something before the context shrinks.
