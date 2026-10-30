const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const root = path.join(__dirname, '..');
const read = name => fs.readFileSync(path.join(root, name), 'utf8');

test('practical starting points link to setup and existing-owner updates', () => {
  const home = read('index.html');
  const guide = read('quickstart.html');
  assert.match(home, /id="start-small"/);
  assert.match(home, /href="#start-small"/);
  for (const id of ['before', 'updating']) {
    assert.ok(home.includes('href="/quickstart.html#' + id + '"'));
    assert.ok(guide.includes('id="' + id + '"'));
  }
  assert.match(home, /No task outcome is guaranteed/);
  assert.match(guide, /Runtime readiness is not proof of provider login/);
  assert.match(guide, /Hosted tenants cannot start local coding jobs/);
});

test('update guidance distinguishes backup, recovery and actual verification', () => {
  const guide = read('quickstart.html');
  for (const text of ['application-consistent backup', 'sleep is not shutdown',
    'previous program and Python environment', 'UPDATE&nbsp;/&nbsp;REINSTALL',
    'provider login separately', 'binary alone does not prove',
    'Older installers may not have the current recovery behavior'])
    assert.ok(guide.includes(text), text);
  assert.doesNotMatch(guide, /Updating: ten minutes|Updates never touch accumulated brain state/);
});

test('new public guidance contains no customer-specific handoff data', () => {
  for (const name of ['index.html', 'quickstart.html']) {
    const html = read(name);
    assert.doesNotMatch(html, /Wesley|vps-133fbb56|\.job-validation|\/opt\/leon-brain/);
  }
});

test('quickstart scripts parse and local fragment targets exist', () => {
  const html = read('quickstart.html');
  for (const match of html.matchAll(/<script\b[^>]*>([\s\S]*?)<\/script>/gi))
    new vm.Script(match[1], {filename:'quickstart.html'});
  for (const match of html.matchAll(/href="#([^"]+)"/g))
    assert.ok(html.includes('id="' + match[1] + '"'), match[1]);
});
