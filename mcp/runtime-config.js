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

// A browser tool call is the only thing that should bring a closed Chrome
// back. initialize, tools/list and notifications come from clients that are
// merely connected, and relaunching for those reopens the window the user
// just closed.
function isBrowserDemand(body) {
  let payload;
  try {
    payload = JSON.parse(body.toString('utf8'));
  } catch {
    return false;
  }
  const messages = Array.isArray(payload) ? payload : [payload];
  return messages.some((m) => m && m.method === 'tools/call');
}

// Decides what the CDP watchdog does while Chrome is unreachable. By default
// it acts only after a client asked for the browser (demandSince): relaunch
// at once, and exit for a supervisor restart if that has not helped within
// bailAfterMs. relaunchWhenIdle restores the old timer-driven behavior.
function decideWatchdogAction({
  now,
  downSince,
  demandSince = null,
  relaunchAfterMs,
  bailAfterMs,
  relaunchWhenIdle = false,
}) {
  if (demandSince !== null) {
    return { relaunch: true, bail: now - demandSince >= bailAfterMs };
  }
  if (!relaunchWhenIdle) return { relaunch: false, bail: false };
  const downMs = now - downSince;
  return { relaunch: downMs >= relaunchAfterMs, bail: downMs >= bailAfterMs };
}

module.exports = {
  DEFAULT_PLAYWRIGHT_OUTPUT_MAX_SIZE,
  buildChromeRelaunchArgs,
  decideWatchdogAction,
  isBrowserDemand,
  resolvePlaywrightOutputConfig,
};
