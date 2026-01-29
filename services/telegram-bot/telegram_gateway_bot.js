const TelegramBot = require('node-telegram-bot-api');
const axios = require('axios');

const TELEGRAM_TOKEN = process.env.TELEGRAM_TOKEN;
const GATEWAY_URL = process.env.GATEWAY_URL || 'http://127.0.0.1:8800/v1/chat/completions';
const GATEWAY_BEARER_TOKEN = process.env.GATEWAY_BEARER_TOKEN;
const GATEWAY_MODEL = process.env.GATEWAY_MODEL || 'auto';
const SYSTEM_PROMPT = process.env.SYSTEM_PROMPT || '';
const MAX_HISTORY = Number.parseInt(process.env.MAX_HISTORY || '20', 10);

if (!TELEGRAM_TOKEN) {
  throw new Error('Missing TELEGRAM_TOKEN');
}

if (!GATEWAY_BEARER_TOKEN) {
  throw new Error('Missing GATEWAY_BEARER_TOKEN');
}

if (Number.isNaN(MAX_HISTORY) || MAX_HISTORY < 1) {
  throw new Error('MAX_HISTORY must be a positive integer');
}

const bot = new TelegramBot(TELEGRAM_TOKEN, { polling: true });
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

bot.setMyCommands(COMMANDS).catch((err) => {
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

function parseCommand(text) {
  const trimmed = text.trim();
  if (!trimmed.startsWith('/')) {
    return null;
  }
  const [commandPart, ...rest] = trimmed.split(' ');
  const command = commandPart.split('@')[0].slice(1).toLowerCase();
  return { command, args: rest.join(' ').trim() };
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

async function handleHistoryExport(chatId, history) {
  if (!history.length) {
    await bot.sendMessage(chatId, 'No history available yet.');
    return;
  }
  const lines = history
    .filter((entry) => entry.role && entry.content)
    .map((entry) => `[${entry.role}] ${entry.content}`)
    .join('\n\n');
  const buffer = Buffer.from(lines, 'utf8');
  await bot.sendDocument(
    chatId,
    buffer,
    { caption: 'Conversation history.' },
    { filename: `chat-${chatId}-history.txt`, contentType: 'text/plain' },
  );
}

async function handlePoll(chatId, args) {
  const segments = args
    .split('|')
    .map((segment) => segment.trim())
    .filter(Boolean);
  const [question, ...options] = segments;
  if (!question || options.length < 2) {
    await bot.sendMessage(
      chatId,
      'Usage: /poll Question | option 1 | option 2 (at least two options required).',
    );
    return;
  }
  await bot.sendPoll(chatId, question, options, { is_anonymous: false });
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
    timeout: 60000, // 60 second timeout
  });

  return res.data?.choices?.[0]?.message?.content || '';
}

bot.on('message', async (msg) => {
  const chatId = msg.chat?.id;
  const userText = msg.text || '';

  if (!chatId) {
    return;
  }

  const commandData = parseCommand(userText);
  if (commandData) {
    const { command, args } = commandData;
    switch (command) {
      case 'start':
        await bot.sendMessage(chatId, 'Welcome! Send a message to chat with the Gateway.');
        return;
      case 'help':
        await bot.sendMessage(chatId, buildHelpText());
        return;
      case 'reset':
        histories.delete(chatId);
        await bot.sendMessage(chatId, 'Conversation reset.');
        return;
      case 'history':
        await handleHistoryExport(chatId, getHistory(chatId));
        return;
      case 'me': {
        const me = await bot.getMe();
        await bot.sendMessage(
          chatId,
          `Bot: ${me.first_name}${me.username ? ` (@${me.username})` : ''} | ID: ${me.id}`,
        );
        return;
      }
      case 'whoami': {
        if (!msg.from?.id) {
          await bot.sendMessage(chatId, 'Unable to determine your user ID.');
          return;
        }
        const member = await bot.getChatMember(chatId, msg.from.id);
        await bot.sendMessage(
          chatId,
          `You are ${member.status} in this chat.${member.user?.username ? ` (@${member.user.username})` : ''}`,
        );
        return;
      }
      case 'chatinfo': {
        const chat = await bot.getChat(chatId);
        const name = chat.title || chat.username || chat.first_name || 'this chat';
        const description = chat.description ? `\nDescription: ${chat.description}` : '';
        await bot.sendMessage(
          chatId,
          `Chat: ${name}\nType: ${chat.type}\nID: ${chat.id}${description}`,
        );
        return;
      }
      case 'poll':
        await handlePoll(chatId, args);
        return;
      default:
        await bot.sendMessage(chatId, 'Unknown command. Use /help for available commands.');
        return;
    }
  }

  if (!userText.trim()) {
    return;
  }

  const history = getHistory(chatId);

  await bot.sendChatAction(chatId, 'typing');

  try {
    const answer = await queryGateway(history, userText);
    // Only update history after successful response
    history.push({ role: 'user', content: userText });
    history.push({ role: 'assistant', content: answer });
    histories.set(chatId, trimHistory(history));
    await bot.sendMessage(chatId, answer || 'No response content.');
  } catch (err) {
    console.error(`Error for chat ${chatId}:`, err.message);
    await bot.sendMessage(chatId, 'Error talking to the gateway.');
  }
});

console.log('Telegram gateway bot is running.');
