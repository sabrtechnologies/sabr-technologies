# Site + SI update audit (2026-11-02)

Internal notes. Not served: server.js only publishes the PAGES and ASSET_DIRS allow-lists.

## Pricing model: Free / Care / Done-for-you (RECOMMENDATION, not tested market data)
Set in index.html, inline script, `SITE_CONFIG` (search `SITE_CONFIG`). Tagged `PLACEHOLDER: pricing under revision`.
- Free: $0, the software plus a buy-list guide (#buy-list) for people who build it themselves.
- Care: $199 / month. Updates designed to keep the SI's memory and identity, support, install-token path.
- Done-for-you: $1,500 one-time setup, then Care monthly. Sabr installs on hardware the customer buys.
- Sabr does not sell or resell hardware. Stated in #buy, the Done-for-you card and #buy-list. No hardware models, vendors, prices, testimonials or counts were added.
Elements with `data-cfg="tiers.x.y"` are filled from SITE_CONFIG by JS. The static HTML carries the same text as the no-JS fallback, so change both when you change a price.
The old Founder / Perpetual / Business / Enterprise cards and the monthly/annual toggle are gone (no real annual price in the new model). The 24-hour Trial card and #trial form are unchanged. A one-line "Talk to us" contact reveal replaces the Business/Enterprise cards for company deployments.

## New sections (2026-11-02, second pass)
- #buy-list is now the Free starter guide: a "what to have ready" checklist plus a six-step ordered guide (#starter-guide), all taken from quickstart.html requirements. No vendors, models or prices. Says Sabr does not sell or resell hardware.
- #founding-rate: a "price rises" step table filled from `SITE_CONFIG.founding.steps` (PLACEHOLDER). Only the first step has a value ($199 / month, now). Next and standard steps read "To be announced" because Dean has given no dates, amounts or seat counts. Keep steps[0].rate equal to tiers.care.price. Static HTML fallback matches SITE_CONFIG.
- #compare: old way vs our way table. Mobile layout stacks each row using data-label.
- #learned: static, hand-updated "what Leon learned or built" list. Every entry cites a real commit from this repo's git log. A copy-paste template is in the HTML comment above the section. Nothing is fetched (CSP).
- Care card is framed as a mind with memory plus support: updates are designed never to erase memory or identity, back up anyway. No course/lesson wording anywhere.

## STRIPE PRICE MUST CHANGE BEFORE DEPLOY (checkout)
The charge comes from the Railway checkout service (https://sabr-checkout-production.up.railway.app) and Stripe, not this page. That service's code is not in this repo.
Its existing plans bill the OLD amounts ("individual" = $7,499/month, "perpetual" = $46,500). A $199 label must never check out at $7,499, so there is NO `.buyBtn` on the page now.
Care and Done-for-you buttons reveal a "Reach Dean directly" contact box (deansabrwork@gmail.com), and the price note says Sabr confirms the amount before payment.
The checkout JS (CHECKOUT_API POST, safeURL to checkout.stripe.com) is kept intact and dormant. To go self-serve: create a $199/month Stripe price and a plan in the Railway service, then change the Care link to `class="pcc buyBtn" data-plan="<new plan>"`.
Done-for-you ($1,500 one-time setup + Care) needs a Stripe price or invoice flow too.

## Free tier and downloads
The page links the GitHub releases page (RELEASES_URL), not a direct tarball. landing-assets/leon-brain-release.tar.gz exists in the repo but was not verified or linked. The trial JS comment says "no public download button anywhere"; Dean should decide whether Free means a public releases link (currently yes) or a gated download.

## SI version source
No version file exists in the repo (landing-assets/RELEASE_COMMIT is a git hash, rebuild.txt is empty, package.json 1.0.0 is not the SI version).
Version `v2026.10.29.1` is the tag that https://github.com/sabrtechnologies/sabr-installers/releases/latest redirected to on 2026-11-02 (curl). It is hand-set in SITE_CONFIG, not read live (CSP connect-src blocks the GitHub API). It goes stale on every release. Update it each time.

## Installer owner mismatch (not changed)
- index.html trial JS (`var B = ...`) downloads from github.com/47-Industries/sabr-installers/releases/latest/download.
- quickstart.html and the new links use github.com/sabrtechnologies/sabr-installers/releases/latest.
- On 2026-11-02 both /releases/latest URLs returned 200 and ended at the sabrtechnologies repo tag v2026.10.29.1. Individual asset download URLs were NOT checked. Decide whether to switch the trial JS and test/onboarding_browser.py.

## Other copy to review
terms.html and refunds.html were cleaned of Founder, Business, Enterprise and the monthly/annual wording to match the three tiers (Free, Care, Done-for-you, plus custom team deployments). Both are still drafts marked noindex and not linked from index.html. Their bracketed windows ([14] days, [72 hours], [5] business days, the pro-rata setup-fee refund) are proposals for Dean, not commitments, and counsel has not reviewed them.

## Tests
test/onboarding_browser.py was updated for the three tiers (not part of `npm run test`; it needs the approved sandbox and Playwright). `npm run test` passes 8/8.
Render check (2026-11-02, second pass; Playwright in a venv under gitignored review-shots/, system chromium, `node server.js` on PORT 3999): at 390, 760, 1024 and 1440 there was no horizontal overflow, no element past the viewport edge, no page errors and no CSP console messages. Tiers sit side by side at 1440 (all three cards 755px tall, so the Care card matches its neighbours) and stack at 1024 and below. The only console error is a 405 on POST /api/onboarding/install-log from js/brainweb-page.html (the embedded brain iframe) against the static dev server; it is not caused by these changes. HTTP: /, /success.html, /quickstart.html, /terms.html, /refunds.html and /landing-assets/installer-token-screen.png return 200; /AUDIT.md returns 404. Static checks: no duplicate ids, every #anchor resolves, all 22 data-cfg fallbacks equal SITE_CONFIG. Screenshots (pricing, compare, founding-rate, buy-list, learned at each width) are in review-shots/ but nobody has looked at them: checks were DOM and geometry only, so visual polish and contrast are not eyeballed. The real Railway/Stripe checkout is untested.
