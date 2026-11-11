# Site + SI update audit

Internal notes. Not served: server.js only publishes the PAGES and ASSET_DIRS allow-lists.

## Pricing (2026-11-11): one offer, installation + Care
Set in index.html, inline script, `SITE_CONFIG` (search `SITE_CONFIG`).
- $10,000 one-time installation fee, then Care at $200 / month.
- The old three tiers (Free $0, Care at the old monthly rate, Done-for-you one-time setup) and their Gmail-only contact boxes were removed, not hidden.
- Sabr does not sell or resell hardware. Stated in #buy, the pricing card and #buy-list.
Elements with `data-cfg="tiers.x.y"` are filled from SITE_CONFIG by JS. The static HTML carries the same text as the no-JS fallback, so change both when you change a price.
The 24-hour Trial card and #trial form are unchanged. The "Talk to us" team contact reveal is kept for custom deployments.
- #founding-rate: steps[0].rate must equal tiers.care.price ($200 / month). Later steps read "To be announced".

## Checkout: Buy button -> sabr-checkout `install` plan
- The pricing card has one `.pcc.buyBtn` with `data-plan="install"`.
- The charge comes from the Railway checkout service (https://sabr-checkout-production.up.railway.app, repo sabrtechnologies/sabr-checkout, branch trial-tokens), not this page.
- The amounts live in sabr-checkout app.py: `INSTALL_FEE_CENTS = 1_000_000` and `CARE_MONTHLY_CENTS = 20_000`, sent to Stripe as inline price_data (one one-time line + one monthly recurring line, mode=subscription). The install plan never falls back to the legacy PRICE_BUILD/PRICE_MONTHLY pair ($12k + $2k/mo).
- The page first GETs /health and only POSTs /create-checkout if `health.install` reports exactly plan=install, currency=usd, fee_cents=1000000, care_monthly_cents=20000 (SITE_CONFIG.CHECKOUT_EXPECT). The currently deployed checkout service (before the install-plan change is deployed) reports no `install` block, so the button refuses and tells the buyer to email. It goes live only once the sabr-checkout change is deployed to Railway.

## Downloads
- #download now has a visible "Download Installer" grid, and the pricing card has a "Download Installer" button linking to it.
- Links: https://github.com/sabrtechnologies/sabr-installers/releases/latest/download/{sabr-installer.deb, SabrInstaller.exe, SabrInstaller-macos.zip, SabrInstaller-macos-intel.zip}. All four returned HTTP 200 (after redirect to GitHub release assets) on 2026-11-11, release v2026.10.29.1.
- An installer does nothing without an install token from checkout or the trial.

## SI version source
Version `v2026.10.29.1` is hand-set in SITE_CONFIG (CSP blocks the GitHub API). Update it each release.

## Installer owner mismatch (not changed)
The trial JS (`var B = ...`) and the checkout service's INSTALLERS_BASE still use github.com/47-Industries/sabr-installers; it redirects to the sabrtechnologies repo and returned 200 on 2026-11-11.

## Other copy
terms.html and refunds.html now describe a one-time installation fee followed by Care. Both remain drafts (noindex, not linked); bracketed windows are proposals for Dean, not reviewed by counsel.

## Deployment fact
sabrtechnologies.com resolves to this VPS (2.25.174.126); Caddy (deploy/sabrtechnologies.conf) serves /opt/leon-brain/workspaces/sabr-technologies, which is reset to origin/master about every 5 minutes. Railway hosts a mirror at sabr-technologies-production.up.railway.app. Pushing master therefore updates the live domain within ~5 minutes.

## Tests
`npm run test` (node --test test/*.test.js). test/onboarding_browser.py needs the approved sandbox and Playwright.
