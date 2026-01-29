# telegram-bot

Telegram bot client for the Gateway OpenAI-style chat API. Provides a simple chat interface through Telegram that connects to the local Gateway service.

## Features

- Connects to Gateway using OpenAI-style chat completions API
- Maintains per-chat conversation history in memory
- Supports optional system prompts
- Automatic history trimming to bound memory usage per chat
- `/reset` command to clear conversation state
- Systemd-managed for automatic startup and monitoring
- 60-second timeout for Gateway requests to prevent hanging

**Note**: Conversation histories are stored in memory and will persist until the service restarts or the `/reset` command is used. For production deployments with many users, consider monitoring memory usage.

## Architecture

- **Runtime directory**: `/var/lib/telegram-bot`
- **App code**: `/var/lib/telegram-bot/app`
- **Environment file**: `/var/lib/telegram-bot/telegram-bot.env`
- **Logs**: `/var/log/telegram-bot` (systemd journal)
- **Service**: `telegram-bot.service`
- **User**: `telegram-bot` (system user, no login)

## Installation

From `services/telegram-bot/scripts/`:

```bash
sudo ./install.sh
```

This will:
1. Create the `telegram-bot` system user
2. Create runtime directories
3. Install the systemd service (Linux) or launchd plist (macOS)
4. Copy the environment file template
5. Copy bot code and install Node.js dependencies
6. Enable the service (Linux) or bootstrap launchd (macOS)

After installation, **edit `/var/lib/telegram-bot/telegram-bot.env`** with your:
- `TELEGRAM_TOKEN`: Get from [@BotFather](https://t.me/BotFather) on Telegram
- `GATEWAY_BEARER_TOKEN`: Your Gateway authentication token

## Configuration

Edit `/var/lib/telegram-bot/telegram-bot.env`:

### Required
- `TELEGRAM_TOKEN`: Telegram bot token from @BotFather
- `GATEWAY_BEARER_TOKEN`: Bearer token for Gateway authentication

### Optional
- `GATEWAY_URL`: Gateway endpoint (default: `http://127.0.0.1:8800/v1/chat/completions`)
- `GATEWAY_MODEL`: Model to use (default: `auto`)
- `SYSTEM_PROMPT`: System message prepended to each chat (default: empty)
- `MAX_HISTORY`: Maximum number of messages to keep in history (default: 20). Note: This is total messages, not user-assistant pairs. System prompts are kept separately.

## Usage

### Start the bot

```bash
sudo systemctl start telegram-bot
```

On macOS:

```bash
sudo launchctl kickstart -k system/com.telegram-bot.server
```

### Check status

```bash
sudo ./status.sh
# or
sudo systemctl status telegram-bot
```

On macOS:

```bash
sudo ./status.sh
# or
sudo launchctl print system/com.telegram-bot.server
```

### View logs

```bash
sudo journalctl -u telegram-bot -f
```

On macOS:

```bash
tail -f /var/log/telegram-bot/telegram-bot.err.log
```

### Restart

```bash
sudo ./restart.sh
# or
sudo systemctl restart telegram-bot
```

On macOS:

```bash
sudo ./restart.sh
```

### Deploy code updates

```bash
sudo ./deploy.sh
```

This copies updated code and restarts the service.

### Uninstall

```bash
sudo ./uninstall.sh
```

This stops the service, removes files, and deletes the user.

## Telegram Commands

- `/start`: Start the bot and show a welcome message
- `/help`: Show available commands
- `/reset`: Clear the conversation history for the current chat
- `/history`: Export the conversation history as a text file
- `/me`: Show bot profile information
- `/whoami`: Show your chat membership status
- `/chatinfo`: Show chat metadata
- `/poll`: Create a poll using `/poll Question | option 1 | option 2`

## Dependencies

Node.js packages (installed automatically by install.sh):
- `node-telegram-bot-api`: Telegram Bot API client
- `axios`: HTTP client for Gateway requests

## Monitoring

The service is configured with:
- `Restart=always`: Automatically restarts on failure
- `RestartSec=5`: 5-second delay between restart attempts
- Systemd journal logging for easy log access

Check service health:
```bash
sudo systemctl is-active telegram-bot
```

On macOS:

```bash
sudo launchctl print system/com.telegram-bot.server
```

## Security Notes

- The bot runs as a dedicated system user with no login shell
- Environment file is set to mode 600 (readable only by owner)
- Tokens are stored in the environment file, not in code
- Only connects to the configured Gateway URL (localhost by default)

## Troubleshooting

### Service won't start
Check logs:
```bash
sudo journalctl -u telegram-bot -n 50
```

Common issues:
- Missing or invalid `TELEGRAM_TOKEN`
- Missing or invalid `GATEWAY_BEARER_TOKEN`
- Gateway service not running
- Node.js dependencies not installed

### Bot not responding
1. Check if the bot is running: `sudo systemctl status telegram-bot`
2. Check Gateway is accessible: `curl http://127.0.0.1:8800/health`
3. Check recent logs: `sudo journalctl -u telegram-bot -n 20`

### Dependencies missing
Reinstall dependencies:
```bash
cd /var/lib/telegram-bot/app
sudo -u telegram-bot npm install --production
sudo systemctl restart telegram-bot
```
