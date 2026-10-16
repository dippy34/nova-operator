// Text-only API worker. No tools, shell dispatch, or pairing credentials.
// A separate process is organization, NOT an OS security boundary (same macOS user).
import { readFileSync, statSync } from 'node:fs';
import { parseEnv } from 'node:util';
import { fileURLToPath } from 'node:url';

export const MODEL = 'claude-haiku-5-5';
export const MAX_OUTPUT = 512;
export const SYSTEM = 'You are Nova, Matthew’s AI companion. Be warm, direct and concise. This version is conversation only. You cannot operate the Mac, browse, run code, inspect files or supervise other agents. Never claim you performed an action. The app has separate Mac status and Repo status buttons. Do not invent their results. You remember only a few recent messages. Reply in at most 200 words.';
const keyFile = fileURLToPath(new URL('../.env.local', import.meta.url));

export function configuredKey() {
  // Keep LaunchAgent plists and IPC free of secrets. Read the private local file here.
  let key;
  try {
    if (statSync(keyFile).mode & 0o077) return '';
    key = parseEnv(readFileSync(keyFile, 'utf8')).ANTHROPIC_API_KEY;
  } catch { return ''; }
  return typeof key === 'string' && key.startsWith('sk-ant-') && key.length > 30 ? key : '';
}

export async function askClaude(messages, { key, signal, fetchImpl = fetch } = {}) {
  if (!key) throw new Error('KEY');
  if (!Array.isArray(messages) || JSON.stringify(messages).length > 12000 || messages.length > 7 ||
      messages.some(m => !['user', 'assistant'].includes(m.role) || typeof m.content !== 'string')) throw new Error('REQUEST');
  const response = await fetchImpl('https://api.anthropic.com/v1/messages', {
    method: 'POST', redirect: 'error', signal,
    headers: { 'content-type': 'application/json', 'x-api-key': key, 'anthropic-version': '2023-06-01' },
    body: JSON.stringify({ model: MODEL, max_tokens: MAX_OUTPUT, system: SYSTEM, messages,
      thinking: { type: 'disabled' } })
  });
  // Never return provider error bodies: they can echo request content or credentials.
  if (!response.ok) throw new Error([401,403].includes(response.status) ? 'AUTH' : response.status === 429 ? 'LIMIT' : 'PROVIDER');
  const data = await response.json();
  const usage = pricedUsage(data);
  const message = (data.content ?? []).filter(b => b.type === 'text' && typeof b.text === 'string').map(b => b.text).join('\n').slice(0,12000);
  if (!message) throw new Error('EMPTY');
  return { message, ...usage };
}
export function pricedUsage(data) {
  const input = data.usage?.input_tokens, output = data.usage?.output_tokens;
  if (!Number.isSafeInteger(input) || !Number.isSafeInteger(output) || input < 0 || input > 20000 || output < 0 || output > MAX_OUTPUT ||
      (data.usage?.cache_creation_input_tokens ?? 0) !== 0 || (data.usage?.cache_read_input_tokens ?? 0) !== 0) throw new Error('USAGE');
  // USD micro-units; rates verified 2026-10-16: $0.10 input / $0.50 output per million.
  return { model: MODEL, inputTokens: input, outputTokens: output,
    costMicros: Math.ceil(input * 0.1 + output * 0.5), truncated: data.stop_reason === 'max_tokens' };
}

if (process.send) {
  process.once('message', async messages => {
    try {
      // The contained worker has no key and no network. Core brokers one bounded
      // request to its fixed provider endpoint over the inherited IPC channel.
      const fetchImpl=async(_url,options)=>await new Promise((ok,reject)=>{
        process.once('message',response=>{
          if(!response.apiResponse)return reject(new Error('NETWORK'));
          ok(Response.json(response.apiResponse.body,{status:response.apiResponse.status}));
        });
        process.send({api:JSON.parse(options.body)});
      });
      const options={key:'broker-managed',fetchImpl,signal:AbortSignal.timeout(25000)};
      const result = await askClaude(messages, options);
      process.send({ result }, () => process.disconnect());
    } catch (error) {
      const code = ['KEY','AUTH','LIMIT','PROVIDER','USAGE','EMPTY','REQUEST'].includes(error.message) ? error.message : 'NETWORK';
      process.send({ code }, () => process.disconnect());
    }
  });
}
