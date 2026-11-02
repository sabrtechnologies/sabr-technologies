# Site + SI update audit (2026-11-02)

Internal notes. Not served: server.js only publishes the PAGES and ASSET_DIRS allow-lists.

## Where to set prices, version and release link
index.html, inline script in the checkout block (search `SITE_CONFIG`).
Tagged `PLACEHOLDER: pricing under revision`. Holds Founder month/year, Perpetual, SI_VERSION, RELEASES_URL.
JS renders from it. The static HTML in #pricing (and the version text in hero/#install/#buy) keeps the same values as the no-JS fallback, so change both when you change a price.
Business ("Custom quote"), Enterprise ("Let's talk") and Trial ("$0") are literal text, not in SITE_CONFIG.
Current values are unchanged: $7,499 / month, $74,990 / year, $46,500 one-time.
The real charge comes from the Railway checkout service / Stripe, not from this page. Changing the page does not change what Stripe bills.

## SI version source
No version file exists in the repo (landing-assets/RELEASE_COMMIT is a git hash, rebuild.txt is empty, package.json 1.0.0 is not the SI version).
Version `v2026.10.29.1` is the tag that https://github.com/sabrtechnologies/sabr-installers/releases/latest redirected to on 2026-11-02 (curl). It is hand-set in SITE_CONFIG, not read live (CSP connect-src blocks the GitHub API). It goes stale on every release. Update it each time.

## Installer owner mismatch (not changed)
- index.html trial JS (`var B = ...`) downloads from github.com/47-Industries/sabr-installers/releases/latest/download.
- quickstart.html links github.com/sabrtechnologies/sabr-installers/releases/latest.
- On 2026-11-02 both /releases/latest URLs returned 200 and ended at the sabrtechnologies repo tag v2026.10.29.1, so the 47-Industries URL currently redirects (likely a repo transfer/rename). Individual asset download URLs were NOT checked. New links use sabrtechnologies. Decide whether to switch the trial JS and test/onboarding_browser.py.

## Unverified
See the final job report for browser render results; if Playwright was not run, the layout at 390/1440 is unverified.
