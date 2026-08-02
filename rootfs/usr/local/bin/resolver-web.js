#!/usr/bin/env node
'use strict';

const fs = require('node:fs');
const http = require('node:http');
const net = require('node:net');
const path = require('node:path');
const { spawn } = require('node:child_process');
const { Resolver } = require('node:dns').promises;

const stateFile = process.env.RESOLV_STATE_FILE || '/root/.config/docker-image/resolver.json';
const port = Number.parseInt(process.env.RESOLV_WEB_PORT || '8787', 10);
const cloudflaredBin = process.env.CLOUDFLARED_BIN || 'cloudflared';
const tunnelRuntimeDir = '/run/cloudflared';
const tunnelPidFile = path.join(tunnelRuntimeDir, 'quick-tunnel.pid');
const tunnelDefaultTarget = process.env.NGINX_UPSTREAM || '127.0.0.1:8080';
const defaults = {
  auto_config: true,
  local_nameserver: '127.0.0.1',
  fallback_nameserver: '1.1.1.1',
  fallback_always: false,
  check_domain: 'example.com',
};
const environmentNames = {
  auto_config: 'RESOLV_AUTO_CONFIG',
  local_nameserver: 'RESOLV_LOCAL_NAMESERVER',
  fallback_nameserver: 'RESOLV_FALLBACK_NAMESERVER',
  fallback_always: 'RESOLV_FALLBACK_ALWAYS',
  check_domain: 'RESOLV_CHECK_DOMAIN',
};

function hasEnvironment(name) {
  return Object.prototype.hasOwnProperty.call(process.env, name);
}

function parseBoolean(value, field) {
  if (value === true || value === false) return value;
  if (value === 'true') return true;
  if (value === 'false') return false;
  throw new Error(`${field} must be true or false`);
}

function validServer(value, field) {
  if (typeof value !== 'string' || net.isIP(value) !== 4) {
    throw new Error(`${field} must be an IPv4 address`);
  }
  return value;
}

function validDomain(value) {
  if (typeof value !== 'string' || value.length > 253 || !/^[A-Za-z0-9.-]+$/.test(value)) {
    throw new Error('check_domain must be a simple DNS name');
  }
  return value;
}

function normalizeTunnelTarget(value) {
  if (typeof value !== 'string' || value.trim().length === 0 || value.length > 255) {
    throw new Error('target must be an HTTP(S) origin such as 127.0.0.1:8080');
  }
  const input = value.trim();
  if (input.includes('://') && !/^https?:\/\//i.test(input)) {
    throw new Error('target must be an HTTP(S) origin such as 127.0.0.1:8080');
  }
  const candidate = /^https?:\/\//i.test(input) ? input : `http://${input}`;
  let parsed;
  try {
    parsed = new URL(candidate);
  } catch {
    throw new Error('target must be an HTTP(S) origin such as 127.0.0.1:8080');
  }
  if (!['http:', 'https:'].includes(parsed.protocol) || parsed.username || parsed.password || parsed.search || parsed.hash) {
    throw new Error('target must be an HTTP(S) origin without credentials or query parameters');
  }
  const hostname = parsed.hostname.toLowerCase();
  const validHostname = net.isIP(hostname) === 4
    || hostname === 'localhost'
    || /^(?=.{1,253}$)[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?$/.test(hostname);
  if (!validHostname || hostname.includes('..')) {
    throw new Error('target hostname must be a valid IPv4 address, localhost, or DNS name');
  }
  if (parsed.port && (!/^\d+$/.test(parsed.port) || Number(parsed.port) < 1 || Number(parsed.port) > 65535)) {
    throw new Error('target port must be between 1 and 65535');
  }
  const pathname = parsed.pathname && parsed.pathname !== '/' ? parsed.pathname : '';
  return `${parsed.protocol}//${hostname}${parsed.port ? `:${parsed.port}` : ''}${pathname}`;
}

function validateConfig(input) {
  return {
    auto_config: parseBoolean(input.auto_config, 'auto_config'),
    local_nameserver: validServer(input.local_nameserver, 'local_nameserver'),
    fallback_nameserver: validServer(input.fallback_nameserver, 'fallback_nameserver'),
    fallback_always: parseBoolean(input.fallback_always, 'fallback_always'),
    check_domain: validDomain(input.check_domain),
  };
}

function readStored() {
  try {
    const value = JSON.parse(fs.readFileSync(stateFile, 'utf8'));
    return value && typeof value === 'object' ? value : {};
  } catch {
    return {};
  }
}

function effectiveConfig() {
  const stored = readStored();
  const hasStoredFile = fs.existsSync(stateFile);
  const config = { ...defaults };
  const locked = {};
  for (const key of Object.keys(environmentNames)) {
    const envName = environmentNames[key];
    if (hasEnvironment(envName)) {
      config[key] = process.env[envName];
      locked[key] = true;
    } else if (Object.prototype.hasOwnProperty.call(stored, key)) {
      config[key] = stored[key];
    }
  }
  try {
    return { config: validateConfig(config), locked, stored: hasStoredFile };
  } catch (error) {
    return { config: { ...defaults }, locked, stored: false, warning: error.message };
  }
}

function writeJson(response, status, payload) {
  const body = JSON.stringify(payload);
  response.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Cache-Control': 'no-store',
    'Content-Length': Buffer.byteLength(body),
  });
  response.end(body);
}

function readBody(request) {
  return new Promise((resolve, reject) => {
    let body = '';
    request.on('data', (chunk) => {
      body += chunk;
      if (Buffer.byteLength(body) > 16384) {
        reject(new Error('request body is too large'));
        request.destroy();
      }
    });
    request.on('end', () => resolve(body));
    request.on('error', reject);
  });
}

async function probe(server, domain) {
  const resolver = new Resolver();
  resolver.setServers([`${server}:53`]);
  let timeout;
  try {
    const result = await Promise.race([
      resolver.resolve4(domain),
      new Promise((_, reject) => {
        timeout = setTimeout(() => reject(new Error('timeout')), 2000);
      }),
    ]);
    return { server, ok: true, addresses: result };
  } catch (error) {
    return { server, ok: false, error: error.code || error.message || 'unavailable' };
  } finally {
    if (timeout) clearTimeout(timeout);
  }
}

async function testConfig(config) {
  const [local, fallback] = await Promise.all([
    probe(config.local_nameserver, config.check_domain),
    probe(config.fallback_nameserver, config.check_domain),
  ]);
  return { local, fallback };
}

function saveConfig(config) {
  fs.mkdirSync(path.dirname(stateFile), { recursive: true, mode: 0o700 });
  try {
    fs.chmodSync(path.dirname(stateFile), 0o700);
  } catch {
    // The /root volume may be mounted with a fixed mode.
  }
  const temporary = `${stateFile}.${process.pid}.tmp`;
  fs.writeFileSync(temporary, `${JSON.stringify({ ...config, updated_at: new Date().toISOString() }, null, 2)}\n`, { mode: 0o600 });
  fs.renameSync(temporary, stateFile);
}

function applyConfig(config) {
  return new Promise((resolve) => {
    const child = spawn('/usr/local/bin/configure-resolv', [], {
      env: {
        ...process.env,
        RESOLV_AUTO_CONFIG: String(config.auto_config),
        RESOLV_LOCAL_NAMESERVER: config.local_nameserver,
        RESOLV_FALLBACK_NAMESERVER: config.fallback_nameserver,
        RESOLV_FALLBACK_ALWAYS: String(config.fallback_always),
        RESOLV_CHECK_DOMAIN: config.check_domain,
        RESOLV_STATE_FILE: stateFile,
      },
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    let stdout = '';
    let stderr = '';
    child.stdout.on('data', (chunk) => { stdout += chunk; });
    child.stderr.on('data', (chunk) => { stderr += chunk; });
    child.on('error', (error) => resolve({ code: 1, stdout, stderr: error.message }));
    child.on('close', (code) => resolve({ code: code ?? 1, stdout, stderr }));
  });
}

let tunnelProcess = null;
let tunnelStopRequested = false;
let tunnelState = {
  url: null,
  target: null,
  started_at: null,
  last_error: null,
  output_tail: '',
};

function readTunnelPid() {
  try {
    const value = Number.parseInt(fs.readFileSync(tunnelPidFile, 'utf8').trim(), 10);
    return Number.isInteger(value) && value > 1 ? value : null;
  } catch {
    return null;
  }
}

function writeTunnelPid(pid) {
  if (!Number.isInteger(pid) || pid <= 1) throw new Error('cloudflared did not return a valid process ID');
  fs.mkdirSync(tunnelRuntimeDir, { recursive: true, mode: 0o700 });
  fs.chmodSync(tunnelRuntimeDir, 0o700);
  const temporary = `${tunnelPidFile}.${process.pid}.tmp`;
  try {
    fs.writeFileSync(temporary, `${pid}\n`, { mode: 0o600 });
    fs.renameSync(temporary, tunnelPidFile);
  } catch (error) {
    try { fs.unlinkSync(temporary); } catch {}
    throw error;
  }
}

function clearTunnelPid(expectedPid) {
  if (expectedPid && readTunnelPid() !== expectedPid) return;
  try { fs.unlinkSync(tunnelPidFile); } catch (error) {
    if (error.code !== 'ENOENT') console.warn(`[resolver-web] Could not remove tunnel PID file: ${error.message}`);
  }
}

function processExists(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return error.code === 'EPERM';
  }
}

function isManagedTunnel(pid) {
  try {
    const args = fs.readFileSync(`/proc/${pid}/cmdline`)
      .toString('utf8')
      .split('\0')
      .filter(Boolean);
    const executableMatches = path.basename(args[0]) === path.basename(cloudflaredBin)
      || (args.length > 1 && path.basename(args[1]) === path.basename(cloudflaredBin));
    return executableMatches
      && args.includes('tunnel')
      && args.includes('--no-autoupdate')
      && args.includes('--url');
  } catch {
    return false;
  }
}

function delay(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

async function waitForProcessExit(pid, attempts = 40) {
  for (let attempt = 0; attempt < attempts; attempt += 1) {
    if (!processExists(pid)) return true;
    await delay(50);
  }
  return !processExists(pid);
}

async function terminateManagedTunnel(pid) {
  if (!processExists(pid)) {
    clearTunnelPid(pid);
    return;
  }
  if (!isManagedTunnel(pid)) {
    console.warn(`[resolver-web] Ignoring stale tunnel PID ${pid}: command does not match managed cloudflared.`);
    clearTunnelPid(pid);
    return;
  }
  try { process.kill(pid, 'SIGTERM'); } catch {}
  if (!await waitForProcessExit(pid)) {
    try { process.kill(pid, 'SIGKILL'); } catch {}
    await waitForProcessExit(pid, 20);
  }
  clearTunnelPid(pid);
}

async function cleanupStaleTunnel() {
  const pid = readTunnelPid();
  if (!pid) {
    clearTunnelPid();
    return;
  }
  console.warn(`[resolver-web] Cleaning up stale cloudflared process ${pid}.`);
  await terminateManagedTunnel(pid);
}

function defaultTunnelTarget() {
  try {
    return normalizeTunnelTarget(tunnelDefaultTarget);
  } catch {
    return 'http://127.0.0.1:8080';
  }
}

function extractTunnelUrl(output) {
  const match = output.match(/https:\/\/[a-z0-9-]+\.trycloudflare\.com(?:\/[^\s]*)?/i);
  return match ? match[0].replace(/[),.;]+$/, '') : null;
}

function tunnelOutput(chunk) {
  tunnelState.output_tail = `${tunnelState.output_tail}${chunk}`.slice(-4096);
  if (!tunnelState.url) {
    const url = extractTunnelUrl(tunnelState.output_tail);
    if (url) tunnelState.url = url;
  }
}

function publicTunnelState() {
  const running = Boolean(tunnelProcess);
  return {
    running,
    pid: running ? tunnelProcess.pid : null,
    url: tunnelState.url,
    target: tunnelState.target,
    started_at: tunnelState.started_at,
    last_error: tunnelState.last_error,
    output_tail: running ? '' : tunnelState.output_tail,
    default_target: defaultTunnelTarget(),
  };
}

async function startTunnel(targetInput) {
  if (tunnelProcess) throw new Error('a temporary tunnel is already running');
  const target = normalizeTunnelTarget(targetInput || tunnelDefaultTarget);
  fs.mkdirSync(tunnelRuntimeDir, { recursive: true, mode: 0o700 });
  tunnelState = {
    url: null,
    target,
    started_at: new Date().toISOString(),
    last_error: null,
    output_tail: '',
  };
  tunnelStopRequested = false;

  let child;
  try {
    child = spawn(cloudflaredBin, ['tunnel', '--no-autoupdate', '--url', target], {
      cwd: '/',
      env: { ...process.env, HOME: tunnelRuntimeDir, XDG_CONFIG_HOME: tunnelRuntimeDir },
      stdio: ['ignore', 'pipe', 'pipe'],
    });
  } catch (error) {
    tunnelState.last_error = error.message;
    throw error;
  }
  tunnelProcess = child;
  child.stdout.on('data', tunnelOutput);
  child.stderr.on('data', tunnelOutput);
  if (Number.isInteger(child.pid)) {
    try {
      writeTunnelPid(child.pid);
    } catch (error) {
      tunnelState.last_error = `could not record cloudflared process: ${error.message}`;
      child.kill('SIGTERM');
      tunnelProcess = null;
      throw new Error(tunnelState.last_error);
    }
  }

  return new Promise((resolve, reject) => {
    let settled = false;
    const finish = (error) => {
      if (settled) return;
      settled = true;
      clearTimeout(timeout);
      if (error) reject(error);
      else resolve(publicTunnelState());
    };
    const timeout = setTimeout(() => {
      tunnelState.last_error = 'cloudflared did not publish a trycloudflare.com URL within 10 seconds';
      child.kill('SIGTERM');
      finish(new Error(tunnelState.last_error));
    }, 10000);
    const checkUrl = () => {
      if (tunnelState.url) finish();
    };
    child.stdout.on('data', checkUrl);
    child.stderr.on('data', checkUrl);
    child.once('error', (error) => {
      tunnelState.last_error = error.message;
      if (tunnelProcess === child) tunnelProcess = null;
      clearTunnelPid(child.pid);
      finish(error);
    });
    child.once('exit', (code, signal) => {
      if (tunnelProcess === child) tunnelProcess = null;
      clearTunnelPid(child.pid);
      if (!tunnelState.url) {
        tunnelState.last_error = `cloudflared exited before creating a tunnel (${signal || `code ${code}`})`;
        finish(new Error(tunnelState.last_error));
      } else if (code !== 0 && !tunnelState.last_error && !tunnelStopRequested) {
        tunnelState.last_error = `cloudflared exited (${signal || `code ${code}`})`;
      }
    });
  });
}

async function stopTunnel() {
  const child = tunnelProcess;
  if (!child) return publicTunnelState();
  tunnelStopRequested = true;
  child.kill('SIGTERM');
  await new Promise((resolve) => {
    const timer = setTimeout(() => {
      if (tunnelProcess === child) child.kill('SIGKILL');
      resolve();
    }, 5000);
    child.once('exit', () => {
      clearTimeout(timer);
      resolve();
    });
  });
  if (tunnelProcess === child) tunnelProcess = null;
  clearTunnelPid(child.pid);
  tunnelState.url = null;
  tunnelState.last_error = null;
  tunnelState.output_tail = '';
  tunnelStopRequested = false;
  return publicTunnelState();
}

async function handle(request, response) {
  const requestUrl = new URL(request.url, `http://${request.headers.host || '127.0.0.1'}`);
  if (request.method === 'GET' && requestUrl.pathname === '/api/resolver') {
    const state = effectiveConfig();
    writeJson(response, 200, {
      ...state,
      state_file: stateFile,
      password_protected: Boolean(process.env.RESOLV_WEB_PASSWORD || process.env.PASSWORD),
    });
    return;
  }

  if (request.method === 'GET' && requestUrl.pathname === '/api/tunnel') {
    writeJson(response, 200, publicTunnelState());
    return;
  }

  if (request.method === 'POST' && requestUrl.pathname === '/api/tunnel/start') {
    let body = {};
    try {
      body = JSON.parse(await readBody(request));
    } catch (error) {
      writeJson(response, 400, { error: error.message || 'invalid JSON' });
      return;
    }
    try {
      writeJson(response, 200, await startTunnel(body.target));
    } catch (error) {
      writeJson(response, 400, { error: error.message || 'could not start temporary tunnel', state: publicTunnelState() });
    }
    return;
  }

  if (request.method === 'POST' && requestUrl.pathname === '/api/tunnel/stop') {
    try {
      writeJson(response, 200, { stopped: true, ...await stopTunnel() });
    } catch (error) {
      writeJson(response, 500, { error: error.message || 'could not stop temporary tunnel' });
    }
    return;
  }

  if (request.method !== 'POST' || !['/api/resolver/test', '/api/resolver/apply'].includes(requestUrl.pathname)) {
    writeJson(response, 404, { error: 'not found' });
    return;
  }

  let body;
  try {
    body = JSON.parse(await readBody(request));
  } catch (error) {
    writeJson(response, 400, { error: error.message || 'invalid JSON' });
    return;
  }

  const state = effectiveConfig();
  const requested = { ...state.config, ...body };
  for (const key of Object.keys(state.locked)) {
    if (state.locked[key]) requested[key] = state.config[key];
  }

  let config;
  try {
    config = validateConfig(requested);
  } catch (error) {
    writeJson(response, 400, { error: error.message });
    return;
  }

  if (requestUrl.pathname === '/api/resolver/test') {
    writeJson(response, 200, { config, results: await testConfig(config) });
    return;
  }

  try {
    saveConfig(config);
    const result = await applyConfig(config);
    writeJson(response, result.code === 0 ? 200 : 500, {
      config,
      applied: result.code === 0,
      output: `${result.stdout}${result.stderr}`.trim(),
    });
  } catch (error) {
    writeJson(response, 500, { error: error.message });
  }
}

if (!Number.isInteger(port) || port < 1 || port > 65535) {
  throw new Error('RESOLV_WEB_PORT must be between 1 and 65535');
}

const server = http.createServer((request, response) => {
  handle(request, response).catch((error) => {
    writeJson(response, 500, { error: error.message || 'internal error' });
  });
});
let shuttingDown = false;
async function shutdown() {
  if (shuttingDown) return;
  shuttingDown = true;
  await stopTunnel();
  server.close(() => process.exit(0));
}
process.on('SIGTERM', shutdown);
process.on('SIGINT', shutdown);

async function startServer() {
  await cleanupStaleTunnel();
  server.listen(port, '127.0.0.1', () => {
    console.log(`[resolver-web] Listening on 127.0.0.1:${port}; state=${stateFile}`);
  });
}

startServer().catch((error) => {
  console.error(`[resolver-web] Could not start: ${error.message}`);
  process.exit(1);
});
