import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import vm from 'node:vm';

const source = await readFile(new URL('../src/main.js', import.meta.url), 'utf8');
const functions = source.slice(source.indexOf('function renderAgentConnection()'), source.indexOf('function renderSettings()'));
const deferred = () => { let resolve; const promise = new Promise(done => { resolve = done; }); return { promise, resolve }; };
const info = { available: true, executablePath: '/Example App/nero', config: { mcpServers: { nero: { command: '/Example App/nero', args: ['mcp', '--data-dir', '/Example Library'] } } }, cliExample: 'nero meetings list' };

function harness({ load = async () => info, write = async () => {} } = {}) {
  const nodes = new Map();
  const byId = id => {
    if (!nodes.has(id)) nodes.set(id, { textContent: '', hidden: false, disabled: false, open: id === 'settings-dialog', focus() { throw Error('Unexpected focus'); } });
    return nodes.get(id);
  };
  const state = { settingsPanel: 'agent' };
  const agentConnection = { info: null, loading: false, error: '', request: 0 };
  let calls = 0;
  const copied = [], timers = new Map();
  const context = vm.createContext({ byId, state, agentConnection, bridge: { agentConnectionInfo: () => { calls += 1; return load(); } },
    navigator: { clipboard: { writeText: async text => { copied.push(text); await write(text); } } },
    copyFeedbackTimers: new Map(), setTimeout: callback => { const key = {}; timers.set(key, callback); return key; }, clearTimeout: key => timers.delete(key),
  });
  vm.runInContext(functions, context);
  return { byId, state, agentConnection, copied, timers, context, get calls() { return calls; } };
}

test('loads only while the agent panel is open and deduplicates renders and tab visits', async () => {
  const pending = deferred();
  const app = harness({ load: () => pending.promise });
  app.state.settingsPanel = 'appearance';
  await app.context.loadAgentConnection();
  assert.equal(app.calls, 0);
  app.state.settingsPanel = 'agent';
  const first = app.context.loadAgentConnection();
  await app.context.loadAgentConnection();
  app.context.renderAgentConnection();
  assert.equal(app.calls, 1);
  assert.equal(app.byId('settings-agent-copy-config').disabled, true);
  pending.resolve(info);
  await first;
  await app.context.loadAgentConnection();
  assert.equal(app.calls, 1);
  assert.equal(app.byId('settings-agent-path').textContent, info.executablePath);
  assert.equal(app.byId('settings-agent-copy-config').disabled, false);
});

test('missing binaries and rejected requests never expose usable configuration', async () => {
  const missing = harness({ load: async () => ({ ...info, available: false }) });
  await missing.context.loadAgentConnection();
  assert.equal(missing.byId('settings-agent-status').textContent, '연결 도구가 포함되지 않은 빌드입니다.');
  assert.equal(missing.byId('settings-agent-copy-config').disabled, true);
  assert.equal(missing.byId('settings-agent-path').textContent, '');
  await missing.context.copyAgentConnection('config');
  assert.equal(missing.copied.length, 0);
  const failed = harness({ load: async () => { throw Error('native unavailable'); } });
  await failed.context.loadAgentConnection();
  assert.match(failed.byId('settings-agent-status').textContent, /불러오지 못했습니다/);
  assert.equal(failed.byId('settings-agent-copy-cli').disabled, true);
});

test('late native replies cannot replace a reopened dialog or move focus', async () => {
  const old = deferred();
  let latest = false;
  const app = harness({ load: () => latest ? Promise.resolve(info) : old.promise });
  const first = app.context.loadAgentConnection();
  app.byId('settings-dialog').open = false;
  app.context.resetAgentConnection();
  await app.context.loadAgentConnection();
  assert.equal(app.calls, 1);
  app.byId('settings-dialog').open = true;
  latest = true;
  await app.context.loadAgentConnection();
  old.resolve({ available: false });
  await first;
  assert.equal(app.byId('settings-agent-copy-config').disabled, false);
  assert.equal(app.agentConnection.info, info);
});

test('copies exact configuration and CLI text with local success and failure feedback', async () => {
  const app = harness();
  await app.context.loadAgentConnection();
  await app.context.copyAgentConnection('config');
  assert.equal(app.copied[0], JSON.stringify(info.config, null, 2));
  assert.equal(app.byId('settings-agent-feedback').textContent, '복사됨');
  await app.context.copyAgentConnection('cli');
  assert.equal(app.copied[1], info.cliExample);
  const failed = harness({ write: async () => { throw Error('clipboard denied'); } });
  await failed.context.loadAgentConnection();
  await failed.context.copyAgentConnection('config');
  assert.match(failed.byId('settings-agent-feedback').textContent, /복사하지 못했습니다/);
});

test('closing during a clipboard request discards late feedback', async () => {
  const pending = deferred();
  const app = harness({ write: () => pending.promise });
  await app.context.loadAgentConnection();
  const copy = app.context.copyAgentConnection('config');
  app.byId('settings-dialog').open = false;
  app.context.resetAgentConnection();
  pending.resolve();
  await copy;
  assert.equal(app.byId('settings-agent-feedback').hidden, true);
  assert.equal(app.timers.size, 0);
});
