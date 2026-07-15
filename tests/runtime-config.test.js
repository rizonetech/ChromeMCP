'use strict';

const assert = require('node:assert/strict');
const path = require('node:path');
const test = require('node:test');

const {
  DEFAULT_PLAYWRIGHT_OUTPUT_MAX_SIZE,
  buildChromeRelaunchArgs,
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
