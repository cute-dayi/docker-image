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
server.listen(port, '127.0.0.1', () => {
  console.log(`[resolver-web] Listening on 127.0.0.1:${port}; state=${stateFile}`);
});
process.on('SIGTERM', () => server.close(() => process.exit(0)));
process.on('SIGINT', () => server.close(() => process.exit(0)));
