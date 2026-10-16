import { fork } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { configuredKey, MODEL } from './claude-worker.mjs';

export const AI_BUDGET_MICROS = 1_000_000; // $1 lifetime allowance, not a daily reset.
export const RESERVATION_MICROS = 10_000; // $0.01 retained on unknown outcomes.
const errors = {
  KEY: 'Add a Claude API key to the private .env.local file on your Mac (permissions 600).',
  AUTH: 'Claude rejected the API key. Check the key and access in Claude Console.',
  LIMIT: 'Claude quota or rate limit reached. Check credits; Nova did not retry.',
  PROVIDER: 'Claude could not complete this request. Nova did not retry.',
  NETWORK: 'Claude connection failed or timed out. Nova did not retry.',
  USAGE: 'Unexpected Claude usage. AI paused for this request; check model pricing and limits.',
  EMPTY: 'Claude returned no reply. Nova did not retry.',
  REQUEST: 'Conversation is too large. Try a shorter message.'
};

export function callWorker(messages, signal) {
  return new Promise((resolve, reject) => {
    if (signal.aborted) return reject(new Error('AI request cancelled'));
    const worker = fork(fileURLToPath(new URL('./claude-worker.mjs', import.meta.url)), [], {
      // Do not inherit service credentials, NODE_OPTIONS or unrelated API keys.
      env: {}, execArgv: [], stdio: ['ignore','ignore','ignore','ipc']
    });
    let finished = false;
    const finish = (error, result) => {
      if (finished) return;
      finished = true; clearTimeout(timer); signal.removeEventListener('abort', abort); worker.kill();
      if (error) reject(error); else resolve(result);
    };
    const abort = () => finish(new Error('AI request cancelled'));
    const timer = setTimeout(() => finish(new Error(errors.NETWORK)), 30000);
    signal.addEventListener('abort', abort, {once:true});
    worker.once('error', () => finish(new Error(errors.NETWORK)));
    worker.once('exit', () => finish(new Error(errors.NETWORK)));
    worker.once('message', data => data.result ? finish(null,data.result) : finish(new Error(errors[data.code] ?? errors.PROVIDER)));
    worker.send(messages, error => { if (error) finish(new Error(errors.NETWORK)); });
  });
}

export function createAI(store, { request = callWorker, configured = () => Boolean(configuredKey()) } = {}) {
  let busy = false;
  return {
    status() { return { configured: configured(), model: MODEL, usedUSD: store.aiSpent()/1e6, allowanceUSD: AI_BUDGET_MICROS/1e6, busy }; },
    async chat(id, deviceId, message, signal) {
      if (!configured()) throw new Error(errors.KEY);
      if (busy) throw new Error('Nova is already answering a message. Please wait.');
      busy = true;
      try {
        const messages = store.aiHistory(deviceId);
        messages.push({role:'user',content:message});
        if (!store.reserveAI(id, RESERVATION_MICROS, AI_BUDGET_MICROS)) throw new Error('Nova reached its $1 AI allowance. Change it locally on the Mac before continuing.');
        // Reserve before dispatch. Timeout/stop/crash retains it because billing is unknown.
        const result = await request(messages, signal);
        if (!Number.isSafeInteger(result.costMicros) || result.costMicros < 0 || result.costMicros > RESERVATION_MICROS) throw new Error(errors.USAGE);
        store.settleAI(id, result.costMicros);
        return { ...result, estimatedUSD: result.costMicros/1e6 };
      } finally { busy = false; }
    }
  };
}
