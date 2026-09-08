const http = require('http');
const fs = require('fs');
const path = require('path');

const MIME = {
  '.html':'text/html; charset=utf-8', '.js':'text/javascript; charset=utf-8',
  '.mjs':'text/javascript; charset=utf-8', '.css':'text/css; charset=utf-8',
  '.json':'application/json', '.svg':'image/svg+xml', '.png':'image/png',
  '.jpg':'image/jpeg', '.jpeg':'image/jpeg', '.webp':'image/webp', '.gif':'image/gif',
  '.ico':'image/x-icon', '.mp3':'audio/mpeg', '.wav':'audio/wav', '.ogg':'audio/ogg',
  '.woff':'font/woff', '.woff2':'font/woff2', '.ttf':'font/ttf',
  '.glb':'model/gltf-binary', '.gltf':'model/gltf+json'
};
const ROOT = __dirname;
const MAX_URL_LENGTH = 8192;
const SECURITY_HEADERS = {
  'X-Content-Type-Options': 'nosniff',
  'Referrer-Policy': 'no-referrer',
  'X-Frame-Options': 'SAMEORIGIN',
  'Content-Security-Policy': [
    "default-src 'self'",
    "base-uri 'self'",
    "object-src 'none'",
    "frame-ancestors 'self'",
    "frame-src 'self'",
    "form-action 'self' https://checkout.stripe.com",
    "script-src 'self' 'unsafe-inline'",
    "style-src 'self' 'unsafe-inline' https://fonts.googleapis.com",
    "font-src 'self' https://fonts.gstatic.com",
    "img-src 'self' data:",
    "media-src 'self'",
    "connect-src 'self' https://sabr-checkout-production.up.railway.app",
    "upgrade-insecure-requests"
  ].join('; '),
  'Permissions-Policy': 'camera=(), microphone=(), geolocation=(), payment=()'
};

const PAGES = new Set(['index.html', 'privacy.html', 'quickstart.html',
  'refunds.html', 'success.html', 'terms.html', 'troubleshooting.html',
  'favicon.ico', 'robots.txt', 'sitemap.xml']);
const ASSET_DIRS = new Set(['landing-assets', 'js', 'vendor', 'shots', 'growth']);

function publicPath(raw) {
  let decoded;
  try { decoded = decodeURIComponent((raw || '/').split('?')[0]); }
  catch { return {status: 400}; }
  if (!decoded.startsWith('/') || /[\\\x00-\x1f]/.test(decoded)) return {status: 400};
  const parts = decoded.split('/').filter(Boolean);
  if (parts.some(p => p.startsWith('.'))) return {status: 404};
  if (!parts.length) parts.push('index.html');
  if (!(parts.length === 1 && PAGES.has(parts[0])) &&
      !(parts.length > 1 && ASSET_DIRS.has(parts[0]))) return {status: 404};
  return {relative: parts.join('/')};
}

function createServer(root = ROOT) {
  const realRoot = fs.realpathSync(root);
  return http.createServer(async (req, res) => {
    for (const [name, value] of Object.entries(SECURITY_HEADERS)) res.setHeader(name, value);
    const fail = status => { res.writeHead(status); res.end(http.STATUS_CODES[status]); };
    if ((req.url || '').length > MAX_URL_LENGTH) return fail(414);
    if (!['GET', 'HEAD'].includes(req.method)) {
      res.setHeader('Allow', 'GET, HEAD');
      return fail(405);
    }
    const target = publicPath(req.url);
    if (target.status) return fail(target.status);
    try {
      const filename = await fs.promises.realpath(path.join(realRoot, target.relative));
      const rel = path.relative(realRoot, filename);
      if (rel === '..' || rel.startsWith('..' + path.sep) || path.isAbsolute(rel)) return fail(404);
      if (publicPath('/' + rel.split(path.sep).join('/')).status) return fail(404);
      const stat = await fs.promises.stat(filename);
      if (!stat.isFile()) return fail(404);
      const ext = path.extname(filename).toLowerCase();
      const cache = ext === '.html' || /\.(?:sha256|sh|ps1)$/.test(filename)
        ? 'no-store, no-cache, must-revalidate' : 'public, max-age=3600';
      res.writeHead(200, {'Content-Type': MIME[ext] || 'application/octet-stream',
        'Content-Length': stat.size, 'Cache-Control': cache});
      if (req.method === 'HEAD') return res.end();
      // Release archives can be large; stream with backpressure instead of
      // allocating an entire archive in memory for every download.
      const stream = fs.createReadStream(filename);
      stream.on('error', () => res.destroy());
      res.on('close', () => stream.destroy());
      stream.pipe(res);
    } catch {
      if (!res.headersSent) fail(404);
      else res.destroy();
    }
  });
}

if (require.main === module) {
  const port = process.env.PORT || 3000;
  createServer().listen(port, () => console.log('Sabr Technologies live on port', port));
}
module.exports = {createServer, publicPath};
