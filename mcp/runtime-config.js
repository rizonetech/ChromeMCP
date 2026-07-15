'use strict';

const os = require('node:os');
const path = require('node:path');

const DEFAULT_PLAYWRIGHT_OUTPUT_MAX_SIZE = 128 * 1024 * 1024;

function resolvePlaywrightOutputConfig(env = process.env, homedir = os.homedir()) {
  const stateHome = env.XDG_STATE_HOME || path.join(homedir, '.local', 'state');
  return {
    outputDir: env.PLAYWRIGHT_MCP_OUTPUT_DIR
      || path.join(stateHome, 'chromemcp', 'artifacts'),
    outputMaxSize: env.PLAYWRIGHT_MCP_OUTPUT_MAX_SIZE
      || String(DEFAULT_PLAYWRIGHT_OUTPUT_MAX_SIZE),
  };
}

function validPort(value) {
  if (!/^\d+$/.test(String(value || ''))) return null;
  const port = Number(value);
  return port >= 1 && port <= 65535 ? port : null;
}

function buildChromeRelaunchArgs({
  cdpEndpoint = '',
  cdpPort = '',
  profileName = '',
  profileDir = '',
} = {}) {
  let port = null;
  try {
    const endpoint = new URL(cdpEndpoint);
    port = validPort(endpoint.port);
    if (!port && endpoint.protocol === 'http:') port = 80;
    if (!port && endpoint.protocol === 'https:') port = 443;
  } catch {}
  port = port || validPort(cdpPort) || 9222;

  const args = ['-Port', String(port)];
  if (profileName) args.push('-ProfileName', profileName);
  if (profileDir) args.push('-ProfileDir', profileDir);
  return args;
}

module.exports = {
  DEFAULT_PLAYWRIGHT_OUTPUT_MAX_SIZE,
  buildChromeRelaunchArgs,
  resolvePlaywrightOutputConfig,
};
