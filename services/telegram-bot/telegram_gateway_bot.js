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

const bot = new TelegramBot(TELEGRAM_TOKEN, { polling: true });
const histories = new Map();

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
  });

  return res.data?.choices?.[0]?.message?.content || res.data?.message?.content || '';
}

bot.on('message', async (msg) => {
  const chatId = msg.chat?.id;
  const userText = msg.text || '';

  if (!chatId) {
    return;
  }

  if (userText.startsWith('/reset')) {
    histories.delete(chatId);
    await bot.sendMessage(chatId, 'Conversation reset.');
    return;
  }

  if (!userText.trim()) {
    return;
  }

  const history = getHistory(chatId);

  await bot.sendChatAction(chatId, 'typing');

  try {
    const answer = await queryGateway(history, userText);
    history.push({ role: 'user', content: userText });
    history.push({ role: 'assistant', content: answer });
    histories.set(chatId, trimHistory(history));
    await bot.sendMessage(chatId, answer || 'No response content.');
  } catch (err) {
    console.error(err);
    await bot.sendMessage(chatId, 'Error talking to the gateway.');
  }
});

console.log('Telegram gateway bot is running.');
