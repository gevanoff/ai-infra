const { Bot, InputFile } = require('grammy');
const axios = require('axios');

const TELEGRAM_TOKEN = process.env.TELEGRAM_TOKEN;
const GATEWAY_PORT = Number.parseInt(process.env.GATEWAY_PORT || '8800', 10);
const GATEWAY_URL = `https://127.0.0.1:${GATEWAY_PORT}/v1/chat/completions`;
const GATEWAY_BEARER_TOKEN = process.env.GATEWAY_BEARER_TOKEN;
const GATEWAY_MODEL = process.env.GATEWAY_MODEL || 'auto';
const SYSTEM_PROMPT = process.env.SYSTEM_PROMPT || '';
const MAX_HISTORY = Number.parseInt(process.env.MAX_HISTORY || '20', 10);
const TELEGRAM_MAX_MESSAGE = Number.parseInt(process.env.TELEGRAM_MAX_MESSAGE || '3900', 10);
const LOG_LEVEL = String(process.env.LOG_LEVEL || 'info').toLowerCase();
const LOG_PREVIEW_CHARS = Number.parseInt(process.env.LOG_PREVIEW_CHARS || '320', 10);
const GATEWAY_SOCKET_TIMEOUT_MS = 60000;

if (!TELEGRAM_TOKEN) {
  throw new Error('Missing TELEGRAM_TOKEN');
}

if (!GATEWAY_BEARER_TOKEN) {
  throw new Error('Missing GATEWAY_BEARER_TOKEN');
}

if (Number.isNaN(MAX_HISTORY) || MAX_HISTORY < 1) {
  throw new Error('MAX_HISTORY must be a positive integer');
}

if (Number.isNaN(TELEGRAM_MAX_MESSAGE) || TELEGRAM_MAX_MESSAGE < 500) {
  throw new Error('TELEGRAM_MAX_MESSAGE must be a positive integer >= 500');
}

if (Number.isNaN(GATEWAY_PORT) || GATEWAY_PORT < 1 || GATEWAY_PORT > 65535) {
  throw new Error('GATEWAY_PORT must be a valid TCP port');
}

if (Number.isNaN(LOG_PREVIEW_CHARS) || LOG_PREVIEW_CHARS < 0) {
  throw new Error('LOG_PREVIEW_CHARS must be a non-negative integer');
}

if (Number.isNaN(GATEWAY_SOCKET_TIMEOUT_MS) || GATEWAY_SOCKET_TIMEOUT_MS < 1000) {
  throw new Error('GATEWAY_SOCKET_TIMEOUT_MS must be a positive integer >= 1000');
}

const bot = new Bot(TELEGRAM_TOKEN);
const histories = new Map();

const COMMANDS = [
  { command: 'start', description: 'Start the bot and show welcome message' },
  { command: 'help', description: 'Show available commands' },
  { command: 'reset', description: 'Clear conversation history for this chat' },
  { command: 'history', description: 'Export conversation history as a text file' },
  { command: 'me', description: 'Show bot profile information' },
  { command: 'whoami', description: 'Show your chat membership status' },
  { command: 'chatinfo', description: 'Show chat metadata' },
  { command: 'poll', description: 'Create a poll: /poll Question | option 1 | option 2' },
];

bot.api.setMyCommands(COMMANDS).catch((err) => {
  console.error('Failed to set bot commands:', err.message);
});

function shouldLog(level) {
  const levels = ['error', 'warn', 'info', 'debug'];
  const current = levels.indexOf(LOG_LEVEL);
  const target = levels.indexOf(level);
  if (current === -1 || target === -1) {
    return true;
  }
  return target <= current;
}

function log(level, message, meta = {}) {
  if (!shouldLog(level)) {
    return;
  }
  const entry = {
    level,
    message,
    time: new Date().toISOString(),
    ...meta,
  };
  const line = JSON.stringify(entry);
  if (level === 'error') {
    console.error(line);
  } else if (level === 'warn') {
    console.warn(line);
  } else {
    console.log(line);
  }
}

function previewText(text) {
  const content = String(text || '');
  if (!LOG_PREVIEW_CHARS) {
    return undefined;
  }
  if (content.length <= LOG_PREVIEW_CHARS) {
    return content;
  }
  return `${content.slice(0, LOG_PREVIEW_CHARS)}…`;
}

function getHistory(chatId) {
  if (!histories.has(chatId)) {
    const initial = [];
    if (SYSTEM_PROMPT) {
      initial.push({ role: 'system', content: SYSTEM_PROMPT });
    }
    histories.set(chatId, initial);
  }
  return histories.get(chatId);
}

function trimHistory(history) {
  const system = history[0]?.role === 'system' ? [history[0]] : [];
  const rest = system.length ? history.slice(1) : history;
  const trimmed = rest.slice(-MAX_HISTORY);
  return [...system, ...trimmed];
}

function buildHelpText() {
  const commandLines = COMMANDS.map((entry) => `/${entry.command} - ${entry.description}`);
  return [
    'Available commands:',
    ...commandLines,
    '',
    'Send any other message to chat with the Gateway.',
  ].join('\n');
}

function splitMessage(text, maxLen) {
  const chunks = [];
  const normalized = String(text || '');
  if (normalized.length <= maxLen) {
    return [normalized];
  }

  const paragraphs = normalized.split(/\n{2,}/);
  let current = '';

  for (const paragraph of paragraphs) {
    const candidate = current ? `${current}\n\n${paragraph}` : paragraph;
    if (candidate.length <= maxLen) {
      current = candidate;
      continue;
    }

    if (current) {
      chunks.push(current);
      current = '';
    }

    if (paragraph.length <= maxLen) {
      current = paragraph;
      continue;
    }

    let start = 0;
    while (start < paragraph.length) {
      chunks.push(paragraph.slice(start, start + maxLen));
      start += maxLen;
    }
  }

  if (current) {
    chunks.push(current);
  }

  return chunks;
}

async function replyLongText(ctx, text) {
  const content = String(text || '');
  if (!content.trim()) {
    await ctx.reply('No response content.');
    return;
  }

  const chunks = splitMessage(content, TELEGRAM_MAX_MESSAGE);
  if (chunks.length > 12) {
    const buffer = Buffer.from(content, 'utf8');
    await ctx.replyWithDocument(new InputFile(buffer, `chat-${ctx.chat.id}-response.txt`), {
      caption: 'Response was too long for chat; sending as a file.',
    });
    return;
  }

  for (const chunk of chunks) {
    await ctx.reply(chunk);
  }
}

async function handleHistoryExport(ctx, history) {
  if (!history.length) {
    await ctx.reply('No history available yet.');
    return;
  }
  const lines = history
    .filter((entry) => entry.role && entry.content)
    .map((entry) => `[${entry.role}] ${entry.content}`)
    .join('\n\n');
  const buffer = Buffer.from(lines, 'utf8');
  await ctx.replyWithDocument(new InputFile(buffer, `chat-${ctx.chat.id}-history.txt`), {
    caption: 'Conversation history.',
  });
}

async function handlePoll(ctx, args) {
  const segments = args
    .split('|')
    .map((segment) => segment.trim())
    .filter(Boolean);
  const [question, ...options] = segments;
  if (!question || options.length < 2) {
    await ctx.reply('Usage: /poll Question | option 1 | option 2 (at least two options required).');
    return;
  }
  await ctx.api.sendPoll(ctx.chat.id, question, options, { is_anonymous: false });
}

async function queryGateway(history, message) {
  const payload = {
    model: GATEWAY_MODEL,
    messages: [...history, { role: 'user', content: message }],
    stream: false,
  };

  try {
    const res = await axios.post(GATEWAY_URL, payload, {
      headers: {
        Authorization: `Bearer ${GATEWAY_BEARER_TOKEN}`,
        'Content-Type': 'application/json',
      },
      timeout: GATEWAY_SOCKET_TIMEOUT_MS,
    });

    return res.data?.choices?.[0]?.message?.content || '';
  } catch (err) {
    if (axios.isAxiosError(err)) {
      log('error', 'Gateway request failed', {
        error: err.message,
        code: err.code,
        status: err.response?.status,
        statusText: err.response?.statusText,
        url: err.config?.url,
        timeout: err.config?.timeout,
        response: err.response?.data,
      });
    } else {
      log('error', 'Gateway request failed', { error: err?.message || String(err) });
    }
    throw err;
  }
}


bot.command('start', async (ctx) => {
  await ctx.reply('Welcome! Send a message to chat with the Gateway.');
});

bot.command('help', async (ctx) => {
  await ctx.reply(buildHelpText());
});

bot.command('reset', async (ctx) => {
  histories.delete(ctx.chat.id);
  await ctx.reply('Conversation reset.');
});

bot.command('history', async (ctx) => {
  await handleHistoryExport(ctx, getHistory(ctx.chat.id));
});

bot.command('me', async (ctx) => {
  const me = await bot.api.getMe();
  await ctx.reply(`Bot: ${me.first_name}${me.username ? ` (@${me.username})` : ''} | ID: ${me.id}`);
});

bot.command('whoami', async (ctx) => {
  if (!ctx.from?.id) {
    await ctx.reply('Unable to determine your user ID.');
    return;
  }
  const member = await ctx.api.getChatMember(ctx.chat.id, ctx.from.id);
  await ctx.reply(`You are ${member.status} in this chat.${member.user?.username ? ` (@${member.user.username})` : ''}`);
});

bot.command('chatinfo', async (ctx) => {
  const chat = await ctx.api.getChat(ctx.chat.id);
  const name = chat.title || chat.username || chat.first_name || 'this chat';
  const description = chat.description ? `\nDescription: ${chat.description}` : '';
  await ctx.reply(`Chat: ${name}\nType: ${chat.type}\nID: ${chat.id}${description}`);
});

bot.command('poll', async (ctx) => {
  const args = String(ctx.match || '').trim();
  await handlePoll(ctx, args);
});

bot.on('message:text', async (ctx) => {
  const userText = ctx.message?.text || '';

  if (!userText.trim()) {
    return;
  }

  log('info', 'Incoming Telegram message', {
    chatId: ctx.chat?.id,
    userId: ctx.from?.id,
    username: ctx.from?.username,
    textPreview: previewText(userText),
  });

  const history = getHistory(ctx.chat.id);

  try {
    await ctx.api.sendChatAction(ctx.chat.id, 'typing');
  } catch (err) {
    log('warn', 'Failed to send chat action', {
      chatId: ctx.chat?.id,
      error: err?.message || String(err),
    });
  }

  try {
    const answer = await queryGateway(history, userText);
    history.push({ role: 'user', content: userText });
    history.push({ role: 'assistant', content: answer });
    histories.set(ctx.chat.id, trimHistory(history));
    log('info', 'Sending Telegram reply', {
      chatId: ctx.chat?.id,
      userId: ctx.from?.id,
      textPreview: previewText(answer),
    });
    await replyLongText(ctx, answer);
  } catch (err) {
    log('error', 'Chat handling failed', {
      chatId: ctx.chat?.id,
      userId: ctx.from?.id,
      error: err?.message || String(err),
    });
    await ctx.reply('Error talking to the gateway.');
  }
});

bot.catch((err) => {
  const error = err?.error || err?.message || err;
  log('error', 'Telegram bot error', {
    error: error?.message || String(error),
    stack: error?.stack,
  });
});

bot.start();
console.log('Telegram gateway bot is running.');
