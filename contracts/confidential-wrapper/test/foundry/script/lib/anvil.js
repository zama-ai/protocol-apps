/*
 * Minimal Anvil process + JSON-RPC helpers shared by the fixture tooling.
 */

import { spawn } from 'node:child_process';
import { createWriteStream } from 'node:fs';

const DEFAULT_PORT = 8545;
const DEFAULT_CHAIN_ID = 31337;

export function rpcUrl(port = DEFAULT_PORT) {
  return `http://localhost:${port}`;
}

export function sleep(ms) {
  return new Promise(resolveSleep => setTimeout(resolveSleep, ms));
}

export async function rpc(url, method, params = []) {
  const response = await fetch(url, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ id: 1, jsonrpc: '2.0', method, params }),
  });
  if (!response.ok) {
    throw new Error(`RPC ${method} failed with HTTP ${response.status}`);
  }
  const body = await response.json();
  if (body.error) {
    const code = body.error.code === undefined ? '' : ` (${body.error.code})`;
    throw new Error(
      body.error.message ? `RPC ${method} failed${code}: ${body.error.message}` : `RPC ${method} failed${code}`,
    );
  }
  return body.result;
}

export async function startAnvil({
  port = DEFAULT_PORT,
  chainId = DEFAULT_CHAIN_ID,
  logPath = '/tmp/convert-anvil.log',
} = {}) {
  const url = rpcUrl(port);

  let portBusy = false;
  try {
    await rpc(url, 'eth_chainId', []);
    portBusy = true;
  } catch {
    // Expected when nothing is listening yet.
  }
  if (portBusy) {
    throw new Error(`Port ${port} is already serving Ethereum RPC at ${url}. Stop that Anvil process first.`);
  }

  console.log('Starting blank Anvil...');
  const log = createWriteStream(logPath, { flags: 'w' });
  const child = spawn('anvil', ['--chain-id', String(chainId), '--port', String(port)], {
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  if (child.pid === undefined) throw new Error('Failed to start Anvil');
  child.stdout.pipe(log, { end: false });
  child.stderr.pipe(log, { end: false });
  child.once('exit', (code, signal) => {
    log.end();
    if (code !== null && code !== 0) console.error(`Anvil exited with code ${code}`);
    if (signal) console.error(`Anvil exited from signal ${signal}`);
  });

  console.log('Waiting for Anvil...');
  for (let i = 0; i < 60; i += 1) {
    if (child.exitCode !== null) throw new Error('Anvil exited before accepting RPC connections');
    try {
      await rpc(url, 'eth_blockNumber', []);
      return child;
    } catch {
      await sleep(500);
    }
  }
  throw new Error('Timed out waiting for Anvil');
}

export async function stopAnvil(child) {
  if (!child || child.exitCode !== null) return;
  child.kill();
  await Promise.race([new Promise(resolveStop => child.once('exit', resolveStop)), sleep(2000)]);
  if (child.exitCode === null) child.kill('SIGKILL');
}
