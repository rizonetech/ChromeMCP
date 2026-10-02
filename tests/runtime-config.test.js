'use strict';

const assert = require('node:assert/strict');
const path = require('node:path');
const test = require('node:test');

const {
  DEFAULT_PLAYWRIGHT_OUTPUT_MAX_SIZE,
  buildChromeRelaunchArgs,
  decideWatchdogAction,
  isBrowserDemand,
  resolvePlaywrightOutputConfig,
} = require('../mcp/runtime-config');

test('Playwright output defaults to user state instead of the current workspace', () => {
  const config = resolvePlaywrightOutputConfig({}, '/home/tester');
  assert.deepEqual(config, {
    outputDir: path.join('/home/tester', '.local', 'state', 'chromemcp', 'artifacts'),
    outputMaxSize: String(DEFAULT_PLAYWRIGHT_OUTPUT_MAX_SIZE),
  });
  assert.equal(DEFAULT_PLAYWRIGHT_OUTPUT_MAX_SIZE, 128 * 1024 * 1024);
});

test('Playwright output honors XDG state and explicit upstream overrides', () => {
  assert.equal(
    resolvePlaywrightOutputConfig({ XDG_STATE_HOME: '/state' }, '/home/tester').outputDir,
    '/state/chromemcp/artifacts',
  );

  assert.deepEqual(
    resolvePlaywrightOutputConfig({
      PLAYWRIGHT_MCP_OUTPUT_DIR: '/custom/artifacts',
      PLAYWRIGHT_MCP_OUTPUT_MAX_SIZE: '4096',
      XDG_STATE_HOME: '/ignored',
    }, '/home/tester'),
    { outputDir: '/custom/artifacts', outputMaxSize: '4096' },
  );
});

test('watchdog relaunch preserves a lane CDP port and profile name', () => {
  assert.deepEqual(buildChromeRelaunchArgs({
    cdpEndpoint: 'http://172.28.112.1:9242',
    profileName: 'ChromeMCP-Codex-2',
  }), [
    '-Port', '9242',
    '-ProfileName', 'ChromeMCP-Codex-2',
  ]);
});

test('watchdog relaunch forwards an explicit profile directory', () => {
  assert.deepEqual(buildChromeRelaunchArgs({
    cdpEndpoint: 'http://172.28.112.1:9432',
    profileName: 'ChromeMCP-Claude',
    profileDir: 'C:\\Users\\Tester\\Chrome Profile',
  }), [
    '-Port', '9432',
    '-ProfileName', 'ChromeMCP-Claude',
    '-ProfileDir', 'C:\\Users\\Tester\\Chrome Profile',
  ]);
});

test('watchdog relaunch falls back to exported or default CDP ports', () => {
  assert.deepEqual(
    buildChromeRelaunchArgs({ cdpEndpoint: 'http://127.0.0.1' }),
    ['-Port', '80'],
  );
  assert.deepEqual(
    buildChromeRelaunchArgs({ cdpEndpoint: 'not a URL', cdpPort: '9555' }),
    ['-Port', '9555'],
  );
  assert.deepEqual(
    buildChromeRelaunchArgs({ cdpEndpoint: 'not a URL', cdpPort: '70000' }),
    ['-Port', '9222'],
  );
});

test('only tools/call counts as browser demand', () => {
  const call = (body) => isBrowserDemand(Buffer.from(JSON.stringify(body)));
  assert.equal(call({ jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name: 'browser_tabs' } }), true);
  assert.equal(call([{ method: 'tools/list' }, { method: 'tools/call' }]), true);
  assert.equal(call({ jsonrpc: '2.0', id: 1, method: 'initialize' }), false);
  assert.equal(call({ jsonrpc: '2.0', id: 2, method: 'tools/list' }), false);
  assert.equal(call({ jsonrpc: '2.0', method: 'notifications/initialized' }), false);
  assert.equal(isBrowserDemand(Buffer.from('not json')), false);
  assert.equal(isBrowserDemand(Buffer.alloc(0)), false);
});

test('watchdog leaves a closed Chrome alone while no client needs it', () => {
  assert.deepEqual(decideWatchdogAction({
    now: 10_000_000, downSince: 0, demandSince: null,
    relaunchAfterMs: 60_000, bailAfterMs: 180_000,
  }), { relaunch: false, bail: false });
});

test('watchdog relaunches immediately and bails late once a client asks for the browser', () => {
  const base = { downSince: 0, relaunchAfterMs: 60_000, bailAfterMs: 180_000 };
  assert.deepEqual(
    decideWatchdogAction({ ...base, now: 500_000, demandSince: 499_000 }),
    { relaunch: true, bail: false },
  );
  assert.deepEqual(
    decideWatchdogAction({ ...base, now: 700_000, demandSince: 500_000 }),
    { relaunch: true, bail: true },
  );
});

test('idle relaunch can be restored explicitly', () => {
  const base = { downSince: 0, demandSince: null, relaunchAfterMs: 60_000, bailAfterMs: 180_000, relaunchWhenIdle: true };
  assert.deepEqual(decideWatchdogAction({ ...base, now: 30_000 }), { relaunch: false, bail: false });
  assert.deepEqual(decideWatchdogAction({ ...base, now: 60_000 }), { relaunch: true, bail: false });
  assert.deepEqual(decideWatchdogAction({ ...base, now: 180_000 }), { relaunch: true, bail: true });
});
