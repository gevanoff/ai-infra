const { Bot, InputFile } = require('grammy');
const axios = require('axios');
const https = require('https');

const TELEGRAM_TOKEN = process.env.TELEGRAM_TOKEN;
const GATEWAY_URL = process.env.GATEWAY_URL || 'https://127.0.0.1:8800/v1/chat/completions';
const GATEWAY_BEARER_TOKEN = process.env.GATEWAY_BEARER_TOKEN;
const GATEWAY_MODEL = process.env.GATEWAY_MODEL || 'auto';
const SYSTEM_PROMPT = process.env.SYSTEM_PROMPT || '';
const MAX_HISTORY = Number.parseInt(process.env.MAX_HISTORY || '20', 10);
const GATEWAY_TLS_INSECURE = new Set(['1', 'true', 'yes', 'on']).has(
  String(process.env.GATEWAY_TLS_INSECURE || '').toLowerCase(),
);

const HTTPS_AGENT = GATEWAY_TLS_INSECURE
  ? new https.Agent({ rejectUnauthorized: false })
  : undefined;

if (!TELEGRAM_TOKEN) {
  throw new Error('Missing TELEGRAM_TOKEN');
}

if (!GATEWAY_BEARER_TOKEN) {
  throw new Error('Missing GATEWAY_BEARER_TOKEN');
}

if (Number.isNaN(MAX_HISTORY) || MAX_HISTORY < 1) {
  throw new Error('MAX_HISTORY must be a positive integer');
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

  const res = await axios.post(GATEWAY_URL, payload, {
    headers: {
      Authorization: `Bearer ${GATEWAY_BEARER_TOKEN}`,
      'Content-Type': 'application/json',
    },
    timeout: 60000,
    httpsAgent: HTTPS_AGENT,
  });

  return res.data?.choices?.[0]?.message?.content || '';
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

  const history = getHistory(ctx.chat.id);

  await ctx.api.sendChatAction(ctx.chat.id, 'typing');

  try {
    const answer = await queryGateway(history, userText);
    history.push({ role: 'user', content: userText });
    history.push({ role: 'assistant', content: answer });
    histories.set(ctx.chat.id, trimHistory(history));
    await ctx.reply(answer || 'No response content.');
  } catch (err) {
    console.error(`Error for chat ${ctx.chat.id}:`, err.message);
    await ctx.reply('Error talking to the gateway.');
  }
});

bot.catch((err) => {
  console.error('Bot error:', err.error || err.message || err);
});

bot.start();
console.log('Telegram gateway bot is running.');
