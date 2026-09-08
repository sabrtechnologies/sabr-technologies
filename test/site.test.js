const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const http = require('node:http');
const vm = require('node:vm');
const {createServer, publicPath} = require('../server');

test('only published paths pass, including encoded attack paths', () => {
  for (const p of ['/.git/config', '/%2egit/config', '/js/../server.js',
    '/server.js', '/package.json', '/tools/build.py', '/deploy/sabrtechnologies.conf',
    '/api/unknown', '/js/%2e%2e/.env']) assert.ok(publicPath(p).status, p);
  assert.equal(publicPath('/%E0%A4%A').status, 400);
  assert.equal(publicPath('/js/%00.js').status, 400);
  assert.equal(publicPath('/').relative, 'index.html');
  assert.equal(publicPath('/landing-assets/bootstrap.sh?fresh=1').relative, 'landing-assets/bootstrap.sh');
});

test('real HTTP server rejects private files and survives malformed requests', async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'sabr-http-'));
  fs.mkdirSync(path.join(root, 'js'));
  fs.writeFileSync(path.join(root, 'index.html'), '<h1>Sabr</h1>');
  fs.writeFileSync(path.join(root, 'server.js'), 'private source');
  fs.symlinkSync(path.join(root, 'server.js'), path.join(root, 'js', 'leak.js'));
  const server = createServer(root);
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', resolve);
  });
  const request = (p, method = 'GET') => new Promise((resolve, reject) => {
    const req = http.request({hostname: '127.0.0.1', port: server.address().port, path:p, method}, res => {
      let body = '';
      res.on('data', chunk => { body += chunk; });
      res.on('end', () => resolve({status:res.statusCode, body, headers:res.headers}));
    });
    req.on('error', reject); req.end();
  });
  try {
    assert.equal((await request('/' + 'a'.repeat(8192))).status, 414);
    assert.equal((await request('/%E0%A4%A')).status, 400);
    for (const p of ['/server.js', '/.git/config', '/js/leak.js', '/missing', '/api/health'])
      assert.equal((await request(p)).status, 404, p);
    assert.equal((await request('/', 'POST')).status, 405);
    const page = await request('/');
    assert.equal(page.status, 200);
    assert.equal(page.body, '<h1>Sabr</h1>');
    assert.equal(page.headers['referrer-policy'], 'no-referrer');
    assert.equal(page.headers['content-security-policy'],
      "default-src 'self'; base-uri 'self'; object-src 'none'; frame-ancestors 'self'; frame-src 'self'; form-action 'self' https://checkout.stripe.com; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; font-src 'self' https://fonts.gstatic.com; img-src 'self' data:; media-src 'self'; connect-src 'self' https://sabr-checkout-production.up.railway.app; upgrade-insecure-requests");
    assert.equal(page.headers['permissions-policy'], 'camera=(), microphone=(), geolocation=(), payment=()');
    assert.equal((await request('/', 'HEAD')).body, '');
  } finally {
    await new Promise(resolve => server.close(resolve));
    fs.rmSync(root, {recursive:true, force:true});
  }
});

test('frontend URLs and clipboard failures stay honest; requests time out', async () => {
  const sandbox = {window:{}, URL, AbortController, navigator:{},
    setTimeout: fn => { sandbox.expire = fn; return 1; }, clearTimeout: () => {}};
  vm.runInNewContext(fs.readFileSync(path.join(__dirname, '../js/site-network.js'), 'utf8'), sandbox);
  const ui = sandbox.window.SabrUI;
  for (const url of ['javascript:alert(1)', 'http://github.com/a',
    'https://github.com.evil.test/a', 'https://user@github.com/a'])
    assert.equal(ui.safeURL(url, ['github.com']), null);
  assert.equal(ui.safeURL('https://github.com/a', ['github.com']), 'https://github.com/a');
  const button = {};
  await ui.copy('key', button);
  assert.match(button.textContent, /unavailable/);
  sandbox.fetch = (url, options) => new Promise((resolve, reject) => {
    options.signal.addEventListener('abort', () => reject(new Error('aborted')));
  });
  const pending = ui.json('/test');
  sandbox.expire();
  await assert.rejects(pending, /aborted/);
});

test('all inline browser scripts parse', () => {
  for (const file of ['index.html', 'success.html']) {
    const html = fs.readFileSync(path.join(__dirname, '..', file), 'utf8');
    for (const match of html.matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script>/gi)) {
      if (/src=|application\/ld\+json/.test(match[1])) continue;
      new vm.Script(match[2], {filename:file});
    }
  }
});
