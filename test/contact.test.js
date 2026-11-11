'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const read = file => fs.readFileSync(path.join(__dirname, '..', file), 'utf8');
const html = read('index.html');
const contact = html.match(/\/\* ── Contact reveal\.[\s\S]*?(?=\/\* ── Checkout:)/)[0];
const address = 'deansabrwork@gmail.com';
const manualCopy = 'Copy unavailable — select the address and copy it';

function browser(clipboardWriter = async () => {}) {
  const panels = {};
  const controls = [];
  const copies = [];
  function element(attributes, textContent = '') {
    return {attributes, textContent, listeners: {},
      getAttribute(name) { return this.attributes[name] ?? null; },
      setAttribute(name, value) { this.attributes[name] = value; },
      addEventListener(name, listener) { this.listeners[name] = listener; }};
  }
  for (const [, attrs] of html.matchAll(/<a\b([^>]*\bdata-contact="[^"]+"[^>]*)>/g)) {
    const attributes = Object.fromEntries([...attrs.matchAll(/([\w-]+)="([^"]*)"/g)].map(match => [match[1], match[2]]));
    const id = attributes['data-contact'];
    const panel = html.match(new RegExp('<div class="contact-box" id="' + id + '"([^>]*)>([\\s\\S]*?)<\\/div>'));
    assert.ok(panel, id + ' has a contact panel');
    panels[id] = {hidden: /\bhidden\b/.test(panel[1]), textContent: panel[2]};
    controls.push(element(attributes));
    copies.push(element({}, 'Copy address'));
  }
  const writes = [];
  const document = {
    getElementById: id => panels[id],
    querySelectorAll: selector => selector === '.contactCta' ? controls : selector === '.contact-copy' ? copies : []
  };
  const sandbox = {window: {}, document, navigator: {}, URL,
    fetch: () => { throw new Error('Contact controls must not make network requests'); }};
  if (clipboardWriter !== null) sandbox.navigator.clipboard = {writeText(text) {
    writes.push(text);
    return clipboardWriter(text);
  }};
  vm.runInNewContext(read('js/site-network.js'), sandbox);
  vm.runInNewContext(contact, sandbox);
  return {panels, controls, copies, writes};
}
function click(node) {
  let prevented = false;
  const completion = node.listeners.click({preventDefault() { prevented = true; }});
  assert.equal(prevented, true, 'no navigation or mail-client handoff');
  return completion;
}

// Pricing is now a single Buy (checkout) path. The only remaining contact
// reveal is the team / custom-deployment line; the Gmail-only Care and
// Done-for-you boxes are gone.
test('the only contact control is the team line, and it declares its target and collapsed state', () => {
  const app = browser();
  assert.deepEqual(app.controls.map(control => control.getAttribute('data-contact')), ['teamBox']);
  for (const control of app.controls) {
    const id = control.getAttribute('data-contact');
    assert.equal(control.getAttribute('href'), '#' + id);
    assert.equal(control.getAttribute('aria-controls'), id);
    assert.equal(control.getAttribute('aria-expanded'), 'false');
    assert.equal(app.panels[id].hidden, true);
    click(control);
    assert.equal(app.panels[id].hidden, false);
    assert.equal(control.getAttribute('aria-expanded'), 'true');
  }
  assert.deepEqual(app.writes, []);
  assert.doesNotMatch(html, /id="careBox"|id="doneBox"/);
});

test('address copy confirmation waits for clipboard completion', async () => {
  const pending = [];
  const app = browser(() => new Promise(resolve => { pending.push(resolve); }));
  for (const copy of app.copies) {
    const completion = click(copy);
    assert.ok(completion && typeof completion.then === 'function');
    assert.equal(copy.textContent, 'Copy address', 'no premature success');
    pending.shift()();
    await completion;
    assert.equal(copy.textContent, 'Copied');
  }
  assert.deepEqual(app.writes, [address]);
});

test('rejected clipboard writes preserve the address and give address-specific manual guidance', async () => {
  let rejectWrite;
  const app = browser(() => new Promise((resolve, reject) => { rejectWrite = reject; }));
  for (const copy of app.copies) {
    const completion = click(copy);
    assert.ok(completion && typeof completion.then === 'function');
    assert.equal(copy.textContent, 'Copy address');
    rejectWrite(new Error('Offline permission denial'));
    await completion;
    assert.equal(copy.textContent, manualCopy);
  }
  assert.deepEqual(app.writes, [address]);
  for (const panel of Object.values(app.panels)) assert.ok(panel.textContent.includes('Reach Dean directly'));
  assert.equal((html.match(/<div class="contact-mail">deansabrwork@gmail\.com<\/div>/g) || []).length, 1);
});

test('unavailable clipboard gives address-specific guidance without claiming success', async () => {
  const app = browser(null);
  for (const copy of app.copies) {
    await click(copy);
    assert.equal(copy.textContent, manualCopy);
  }
  assert.deepEqual(app.writes, []);
});
