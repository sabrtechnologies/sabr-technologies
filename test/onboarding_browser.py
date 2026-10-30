"""Offline browser acceptance. Run only through the approved host sandbox.
Usage: python3 test/onboarding_browser.py RESULTS_DIRECTORY
No real checkout, token issuance, provider call or external navigation occurs.
"""
import json
import mimetypes
import os
from pathlib import Path
import sys
from urllib.parse import urlsplit
from playwright.sync_api import sync_playwright

if os.environ.get('LEON_TEST_SANDBOX') != '1':
    raise SystemExit('Use the approved sandbox')
ROOT = Path(__file__).resolve().parents[1]
OUT = Path(sys.argv[1])
OUT.mkdir(parents=True, exist_ok=True)
BASE = 'https://website.test'
CHECKOUT = 'https://sabr-checkout-production.up.railway.app'
checks = []
requests = []

def check(label, condition):
    checks.append({'check': label, 'passed': bool(condition)})
    print(('PASS ' if condition else 'FAIL ') + label, flush=True)
    assert condition, label

def route_request(route):
    req = route.request
    url = urlsplit(req.url)
    if req.url == CHECKOUT + '/create-checkout':
        requests.append({'url': req.url, 'method': req.method, 'body': req.post_data_json})
        route.fulfill(status=503, content_type='application/json', body='{"error":"Offline fixture unavailable"}')
        return
    if req.url.startswith(CHECKOUT + '/install?'):
        requests.append({'url': req.url, 'method': req.method})
        route.fulfill(status=200, content_type='application/json', body=json.dumps({
            'ok': True, 'pending': False, 'token': 'OFFLINE-FIXTURE-NOT-A-TOKEN',
            'installers': {k: 'https://github.com/47-Industries/sabr-installers/releases/latest/download/' + v for k, v in {
                'linux': 'sabr-installer', 'windows': 'SabrInstaller.exe',
                'macos': 'SabrInstaller-macos.zip', 'macos_intel': 'SabrInstaller-macos-intel.zip'}.items()}}))
        return
    if req.url == BASE + '/api/onboarding/create-account':
        requests.append({'url': req.url, 'method': req.method, 'body': req.post_data_json})
        route.fulfill(status=503, content_type='application/json', body='{"error":"Offline trial fixture"}')
        return
    if url.netloc == 'website.test' and req.method == 'GET':
        # Keep unrelated brain visualization and personal export out of this fixture.
        if url.path == '/js/brainweb-page.html':
            route.fulfill(status=200, content_type='text/html', body='<p>Isolated visualization fixture</p>')
            return
        target = (ROOT / (url.path.lstrip('/') or 'index.html')).resolve()
        allowed = target.parent == ROOT and target.name in ('index.html', 'quickstart.html', 'success.html', 'troubleshooting.html')
        allowed = allowed or target == ROOT / 'js/site-network.js'
        allowed = allowed or (target.parent == ROOT / 'landing-assets' and target.suffix in ('.png', '.webp', '.svg'))
        if allowed and target.is_file():
            route.fulfill(status=200, content_type=mimetypes.guess_type(target)[0] or 'application/octet-stream', body=target.read_bytes())
            return
    # Fonts and all other external requests are blocked. No route.continue().
    route.abort()

with sync_playwright() as p:
    browser = p.chromium.launch(executable_path='/usr/bin/chromium', args=['--mute-audio', '--disable-dev-shm-usage'])
    try:
        for width, height in [(1440, 900), (390, 844)]:
            context = browser.new_context(viewport={'width': width, 'height': height}, reduced_motion='reduce', service_workers='block')
            context.route('**/*', route_request)
            page = context.new_page()
            errors = []
            page.on('pageerror', lambda error: errors.append(str(error)))
            page.goto(BASE + '/', wait_until='load')
            check(f'{width} practical hero', 'working relationship' in page.locator('h1').inner_text())
            check(f'{width} home no horizontal overflow', page.evaluate('document.documentElement.scrollWidth <= innerWidth'))
            page.screenshot(path=str(OUT / f'hero-{width}.png'))
            page.get_by_role('link', name='See where to start').click()
            check(f'{width} practical anchor', page.url.endswith('#start-small'))
            check(f'{width} three starting points', page.locator('#start-small .card').count() == 3)
            page.locator('#start-small').screenshot(path=str(OUT / f'outcomes-{width}.png'))
            page.locator('#start-small a[href="/quickstart.html#before"]').click()
            check(f'{width} setup route', page.url.endswith('/quickstart.html#before'))
            check(f'{width} setup visible', page.locator('#before h2').is_visible())
            page.locator('#before').screenshot(path=str(OUT / f'setup-{width}.png'))
            page.locator('#before a[href="#updating"]').click()
            check(f'{width} update anchor', page.url.endswith('#updating'))
            check(f'{width} update backup guidance', 'application-consistent backup' in page.locator('#updating').inner_text())
            check(f'{width} guide no horizontal overflow', page.evaluate('document.documentElement.scrollWidth <= innerWidth'))
            page.locator('#updating').screenshot(path=str(OUT / f'update-{width}.png'))
            if width == 390:
                page.locator('#navBurger').click()
                check('mobile menu opens', page.locator('#navLinks').is_visible())
                page.locator('#navLinks a[href="/"]').click()
                check('mobile home navigation', page.url == BASE + '/')
            else:
                page.goto(BASE + '/', wait_until='load')
            # Exercise existing payment UI only against explicit failure fixtures.
            page.locator('#bYear').click()
            check(f'{width} unchanged annual price', page.locator('#iAmt').inner_text() == '$74,990')
            page.locator('.buyBtn[data-plan="individual"]').click()
            page.wait_for_function("document.querySelector('.buyBtn[data-plan=individual]').parentNode.querySelector('.buyMsg').textContent.includes('Offline fixture')")
            check(f'{width} annual checkout payload', requests[-1]['body'] == {'plan': 'individual', 'interval': 'year'})
            page.locator('#bMonth').click()
            check(f'{width} unchanged monthly price', page.locator('#iAmt').inner_text() == '$7,499')
            page.locator('.buyBtn[data-plan="perpetual"]').click()
            page.wait_for_function("document.querySelector('.buyBtn[data-plan=perpetual]').parentNode.querySelector('.buyMsg').textContent.includes('Offline fixture')")
            check(f'{width} perpetual payload', requests[-1]['body'] == {'plan': 'perpetual', 'interval': 'month'})
            page.locator('#tName').fill('Offline Fixture')
            page.locator('#tEmail').fill('fixture@example.invalid')
            page.locator('#tPhone').fill('0000000000')
            page.locator('#tAddress').fill('Offline fixture only')
            page.locator('#tSi').fill('Fixture')
            page.locator('#tGo').click()
            page.wait_for_function("document.getElementById('tMsg').textContent.includes('Offline trial fixture')")
            check(f'{width} unchanged trial fields', requests[-1]['body'] == {
                'userName': 'Offline Fixture', 'email': 'fixture@example.invalid', 'phone': '0000000000',
                'address': 'Offline fixture only', 'siName': 'Fixture', 'business': '24-hour free trial'})
            page.goto(BASE + '/?paid=1&session_id=offline_fixture', wait_until='load')
            page.wait_for_selector('#key')
            check(f'{width} payment return preserved', page.url == BASE + '/success.html?session_id=offline_fixture')
            check(f'{width} token fixture renders', page.locator('#key').inner_text() == 'OFFLINE-FIXTURE-NOT-A-TOKEN')
            links = page.locator('.dl-grid a').evaluate_all('(els) => els.map(e => e.href)')
            check(f'{width} unchanged four download destinations', links == [
                'https://github.com/47-Industries/sabr-installers/releases/latest/download/' + name for name in
                ['sabr-installer.deb', 'SabrInstaller.exe', 'SabrInstaller-macos.zip', 'SabrInstaller-macos-intel.zip']])
            check(f'{width} no script errors', errors == [])
            context.close()
    finally:
        browser.close()
        (OUT / 'browser-results.json').write_text(json.dumps({'checks': checks, 'mock_requests': requests,
            'limitations': 'Network-isolated fixtures; external fonts blocked and brain iframe substituted. No live payment, issuance, native install or customer machine test.'}, indent=2))
