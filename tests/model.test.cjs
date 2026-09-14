const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const source = fs.readFileSync(path.join(__dirname, '../BarWidget.qml'), 'utf8');
// Execute actual QML JavaScript bodies, not a reimplementation of the model.
function body(name, text = source) {
  const start = text.indexOf('  function ' + name + '(');
  assert(start >= 0, name);
  const end = text.indexOf('\n  }', start) + 4;
  return text.slice(start, end);
}
const ctx = vm.createContext({
  main: {trackedWindows: [], aliveWindowIds: {}},
  Settings: {data: {dock: {pinnedApps: []}}},
  CompositorService: {getActiveWorkspaces: () => [{id: 1}]},
  screen: {name: 'A'}, onlySameOutput: false, onlyActiveWorkspaces: false,
  keepBackgroundApps: true, showPinnedApps: false,
  sessionSeenApps: {}, sessionAppOrder: [], combinedModel: [],
  titleAppFallbacks: {wechat: 'wechat-desktop', 'WeChat': 'wechat-desktop'},
  resolveToDesktopEntryId: id => id === 'wechat-desktop' ? 'wechat' : id,
  findDesktopEntryByTitle: () => null,
  getAppNameFromDesktopEntry: id => id,
  isAppIdPinned: () => false, isDockNoiseWindow: () => false,
  sortApps: groups => groups, updateHasWindow: () => {},
  resolveIconSource: () => '', pluginApi: {},
});
for (const name of ['normalizeAppId', 'getAppKey', 'primaryWindow', 'snapshotWindow',
                    'validWindows', 'rememberSessionAppInto', 'resolveAppIdentity', 'updateCombinedModel']) {
  vm.runInContext(body(name), ctx);
}
function win(id, appId = 'app') {
  return {id, trackId: id, appId, title: appId, workspaceId: 1, output: 'A'};
}
ctx.main.trackedWindows = [win('1'), win('1')];
ctx.updateCombinedModel();
assert.equal(ctx.combinedModel.length, 1);
assert.equal(ctx.combinedModel[0].count, 1, 'duplicate window ID counted twice');
ctx.main.trackedWindows = [];
ctx.updateCombinedModel();
assert.equal(ctx.combinedModel.length, 0, 'unconfirmed process left ghost icon');
ctx.main.aliveWindowIds = {'1': true};
ctx.updateCombinedModel();
assert.equal(ctx.combinedModel[0].type, 'background');
assert.equal(ctx.combinedModel[0].count, 0);
ctx.main.aliveWindowIds = {};
ctx.updateCombinedModel();
assert.equal(ctx.combinedModel.length, 0, 'exit event did not remove icon');
ctx.main.trackedWindows = [win('2'), win('3')];
ctx.main.aliveWindowIds = {'2': true, '3': true};
ctx.updateCombinedModel();
assert.equal(ctx.combinedModel[0].count, 2);
ctx.main.stackAppId = 'app';
ctx.pluginApi.panelOpenScreen = ctx.screen;
ctx.main.setStackPicker = payload => { ctx.picker = payload; };
ctx.main.trackedWindows = [win('3')];
ctx.updateCombinedModel();
assert.equal(ctx.picker.windows.length, 1, 'picker retained closed window');
ctx.main.trackedWindows = [];
ctx.updateCombinedModel();
assert.equal(ctx.picker.windows.length, 0);
ctx.main.stackAppId = '';
ctx.main.trackedWindows = [win('4', 'old')];
ctx.updateCombinedModel();
ctx.main.trackedWindows = [win('4', 'new')];
ctx.main.aliveWindowIds = {'4': true};
ctx.updateCombinedModel();
ctx.main.trackedWindows = [];
ctx.updateCombinedModel();
assert.deepEqual(Array.from(ctx.combinedModel, g => g.appId), ['new'], 'identity change left duplicate app');
ctx.main.trackedWindows = [Object.assign(win('4', 'new'), {output: 'B'})];
ctx.onlySameOutput = true;
ctx.updateCombinedModel();
assert.equal(ctx.combinedModel.length, 0, 'filtered window became background icon');
assert.equal(ctx.resolveAppIdentity({appId: 'browser', title: 'WeChat'}).appId, 'browser');
assert.equal(ctx.resolveAppIdentity({appId: 'wechat', title: ''}).appId, 'wechat');
ctx.main.trackedWindows = [];
ctx.main.aliveWindowIds = {};
ctx.showPinnedApps = true;
ctx.Settings.data.dock.pinnedApps = ['pinned', 'pinned'];
ctx.updateCombinedModel();
assert.equal(ctx.combinedModel.length, 1, 'duplicate pinned ID');
let focused = 0;
ctx.CompositorService.focusWindow = () => { focused++; };
ctx.pluginApi.closePanel = () => {};
ctx.main.clearStackPicker = () => {};
const panel = fs.readFileSync(path.join(__dirname, '../Panel.qml'), 'utf8');
vm.runInContext(body('focusWindow', panel), ctx);
ctx.main.trackedWindows = [Object.assign(win('reused'), {trackId: 'new-life'})];
ctx.focusWindow(Object.assign(win('reused'), {trackId: 'old-life'}));
assert.equal(focused, 0, 'stale picker focused a reused address');
ctx.focusWindow(ctx.main.trackedWindows[0]);
assert.equal(focused, 1, 'current picker window cannot be focused');
console.log('TASKDOCK_MODEL_TESTS_OK');
