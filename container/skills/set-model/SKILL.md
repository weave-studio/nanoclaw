---
name: set-model
description: Switch the Claude model used for this group's conversations. Use when the user asks to change models (e.g., "use Opus", "switch to Haiku", "use Sonnet").
---

# Switch Claude Model

When the user asks to change models, write an IPC file to `/workspace/ipc/tasks/`:

```bash
cat > /tmp/ipc-msg.json << 'IPCEOF'
{
  "type": "set_model",
  "model": "MODEL_ID_HERE",
  "chatJid": "CHAT_JID",
  "groupFolder": "GROUP_FOLDER",
  "timestamp": TIMESTAMP
}
IPCEOF
FILENAME="$(date +%s)-$(head -c 6 /dev/urandom | base64 | tr -dc 'a-z0-9' | head -c 6).json"
mv /tmp/ipc-msg.json "/workspace/ipc/tasks/$FILENAME"
```

Replace the placeholders:
- `MODEL_ID_HERE`: one of the valid model IDs below
- `CHAT_JID`: read from `$NANOCLAW_CHAT_JID` environment variable
- `GROUP_FOLDER`: read from `$NANOCLAW_GROUP_FOLDER` environment variable
- `TIMESTAMP`: current epoch milliseconds

## Valid model IDs

| Model | ID | Best for |
|-------|----|----------|
| Opus | `claude-opus-4-6` | Complex reasoning, nuanced tasks |
| Sonnet | `claude-sonnet-4-6` | Balanced speed and capability |
| Haiku | `claude-haiku-4-5-20251001` | Fast, cost-effective tasks |

To reset to the system default, set `"model": null`.

The change takes effect on the **next message** (the current session is already running).
