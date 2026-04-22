# DialtoneApp Desktop v0.0.1 public release plan

## Progress update - April 22, 2026

### Implemented in the first app slice

- Native app display name remains `DialtoneApp Desktop`.
- Debug build version is set to `0.0.1`.
- The macOS app runs as a menu bar app and can keep running after the main window closes.
- Menu bar label now supports the favicon-derived icon with a red dot when `unseenCandidateCount > 0`.
- Menu bar menu now shows scanner state, unseen/pending counts, top candidates, `Open DialtoneApp Desktop`, `View Log`, `Reveal Log Files`, and `Pause Bot` / `Resume Bot`.
- `View Log` opens a dedicated log window.
- Local logs are written under:
  - `~/Library/Logs/DialtoneApp Desktop/agent.log`
  - `~/Library/Logs/DialtoneApp Desktop/network.log`
  - `~/Library/Logs/DialtoneApp Desktop/purchases.log`
- App support directory is created under `~/Library/Application Support/DialtoneApp Desktop/`.
- The hard-coded scan corpus from this plan is now included in the app.
- Scanner starts with the first 10 high-signal domains.
- Scanner probes the planned well-known, OpenAPI, products, robots, sitemap, and homepage URLs.
- Scanner logs one structured network entry per request.
- Scanner does shallow same-host discovered URL following with a 20 URL cap per domain.
- Initial parsers are implemented for:
  - Shopify-style `products.json`
  - WooCommerce Store API products
  - OpenAPI / Swagger paths and operations
  - Generic commerce/product JSON
  - JSON-LD Product data
  - OpenGraph product fallbacks
- Candidate dedupe uses a SHA-256 fingerprint of domain, title, price, source URL, and product URL.
- `Found Items` UI now shows live discovered candidates instead of static examples.
- Candidate cards include merchant, title, price, description, image when available, source URL, source kind, confidence, and purchase strategy.
- Candidate cards support `No`, `Yes, buy`, and `Open source`.
- `No` marks the candidate dismissed and logs the decision.
- `Yes, buy` starts a `PurchaseCoordinator` flow and logs the decision.
- Purchase flow currently checks for a Keychain desktop session token, opens `https://dialtoneapp.com/login` if missing, checks the saved bot-buyer card endpoint if logged in, opens `https://dialtoneapp.com/bot-buyer` if no saved card is reported, and posts purchase requests to the proposed DialtoneApp Network endpoint.
- Result states are modeled and displayed: purchased, needs login, needs bot-buyer card, needs browser checkout, unsupported merchant, policy blocked, and failed.
- App sandbox is disabled for this target so the scanner can make outbound requests and write the required local log paths.

### Verified

- `xcodebuild -project DialtoneApp.xcodeproj -scheme DialtoneApp -configuration Debug -destination 'platform=macOS' build` succeeds.

### Follow-up scanner fixes - April 22, 2026

- Reviewed live logs under `~/Library/Logs/DialtoneApp Desktop/` and confirmed the high-signal batch completed with network entries and candidate creation.
- Tightened discovered URL cleanup so markdown-style trailing punctuation such as `):` is stripped before follow-up fetches.
- Removed generic `api` as a shallow-follow trigger and replaced it with more commerce-specific tokens such as `price`, `purchase`, `artifact`, `api-doc`, and `wp-json/wc/store/products`.
- Added a pre-fetch binary asset guard for discovered URLs with attachment, image, media, upload, static, and CDN-image style paths.
- Added first-price extraction for text such as `$1`, `$0.001`, `USD 1.00`, and `1.00 USD` in titles and descriptions.
- Applied text-price fallback in OpenAPI, generic JSON, JSON-LD, OpenGraph, Shopify, and WooCommerce parsing.
- Strengthened candidate dedupe across a whole domain report by normalized title, domain, and price instead of only exact candidate fingerprints.
- Changed candidate fingerprinting to normalize titles and avoid treating different source files for the same product as distinct user-facing candidates.
- Re-ran `xcodebuild -project DialtoneApp.xcodeproj -scheme DialtoneApp -configuration Debug -destination 'platform=macOS' build`; the build succeeds after these scanner fixes.

### Still pending for public v0.0.1

- Real desktop login request creation endpoint.
- Custom URL scheme registration for `dialtoneapp-desktop://auth/callback?code=...`.
- Auth callback handling and code exchange.
- Keychain write path for the exchanged desktop session token.
- Durable SQLite store for domain reports, network calls, discovered API calls, and purchase candidates.
- `settings.json` persistence for scan enabled, budget, approval settings, and dismissed candidates.
- Per-domain successful re-scan cadence of 6 hours.
- Failed-domain exponential backoff persistence.
- Budget and policy enforcement before sending any real purchase request.
- Backend contract hardening for `GET /api/users/me/network-card`.
- Backend contract hardening for `POST /api/users/me/bot-purchases`.
- More complete x402 payment-required metadata parsing.
- More complete UCP, commerce manifest, and agent-card schema parsing.
- Browser handoff result polish for unsupported merchants.
- Release archive/signing/notarization pass.

## Goal

Ship a public v0.0.1 of DialtoneApp Desktop that runs as a native macOS menu bar app, scans a fixed corpus of bot-buyable domains, logs every network call, extracts product or paid API opportunities, and asks the user whether DialtoneApp Desktop should buy a found item.

This release does not need broad personalization, category search, ranking intelligence, or perfect checkout coverage. The important thing is proving the loop:

1. Start with only a domain.
2. Discover commerce, catalog, OpenAPI, UCP, x402, or other machine-readable buying surfaces.
3. Extract product/action candidates with title, price, description, and image when available.
4. Notify the user from the menu bar with a red dot when a new candidate is found.
5. Let the user approve or reject.
6. If approved, route through DialtoneApp login, saved bot-buyer card checks, and the DialtoneApp Network purchase path.
7. Keep enough logs to debug every network call and every decision.

## Release scope

### Must ship

- Native app name and UI copy: `DialtoneApp Desktop`.
- Menu bar app that can keep running after the main window closes.
- Menu bar red-dot state when there are unseen product/action candidates.
- Menu option: `View Log`.
- File logs written locally.
- Hard-coded scan corpus from the April 2026 AI bot buying report.
- Background scanner with conservative scheduling and per-domain backoff.
- Discovery from a domain only, with no search engine dependency.
- Product/action cards with merchant, title, price, description, image if available, source URL, and discovered payment/checkout method.
- Approval UI: `No` dismisses or snoozes; `Yes, buy` starts the purchase flow.
- DialtoneApp auth/card gate:
  - If the user is not logged into DialtoneApp Desktop, open the default browser to `https://dialtoneapp.com/login`.
  - If the user is logged in but has no saved bot-buyer card, open `https://dialtoneapp.com/bot-buyer`.
  - If the user is logged in and has a saved bot-buyer card, send a purchase request through DialtoneApp Network.
- A clear result state after approval: purchased, needs browser handoff, blocked by policy, failed, or unsupported.

### Explicitly not required for v0.0.1

- Natural language shopping requests.
- Personalized recommendations.
- Full arbitrary web checkout automation.
- Browser form filling.
- Wallet custody.
- x402 settlement from the desktop app itself.
- Perfect extraction across every domain.
- Merchant onboarding UI inside the desktop app.

## Hard-coded scan corpus

Source: `/Users/aa/dev/dialtoneapp/src/pages/AiBotBuyingReport/index.jsx`, `siteNames`.

The v0.0.1 scanner should hard-code this list in the app or a bundled JSON file:

- www.aloyoga.com
- gymshark.com
- www.reebok.com
- www.campusshoes.com
- redtape.com
- giva.co
- palmonas.com
- mzwallace.com
- www.davidsbridal.com
- saya.pk
- nishatlinen.com
- libas.in
- august.com
- lockly.com
- wyze.com
- www.aosulife.com
- kunasystems.com
- shelly.cloud
- www.brilliant.tech
- www.ezlo.com
- sensibo.com
- ecoflow.com
- avm.de
- boat-lifestyle.com
- jbhifi.com.au
- nzxt.com
- fender.com
- www.gibson.com
- www.uaudio.com
- nixplay.com
- vaku.in
- yotoplay.com
- brooklinen.com
- parachutehome.com
- daisonet.com
- deodap.in
- society6.com
- www.pepstores.com
- www.mccormick.com
- discoverpilgrim.com
- glossier.com
- innovist.com
- www.gharsoaps.shop
- bodybuilding.com
- morenutrition.de
- myfonts.com
- www.vwthemes.com
- shrinetheme.com
- www.hulkapps.com
- www.versobooks.com
- harpercollins.com
- worldofbooks.com
- awaytravel.com
- www.decathlon.com
- anybrowse.dev
- stableemail.dev
- api.zeroreader.com
- blockrun.ai
- openrouter.ai
- x402engine.app
- x402stt.dtelecom.org
- publish.new
- pull.md
- well-knowns.resolved.sh
- x402.quicknode.com
- api.nansen.ai
- emc2ai.io
- api.myceliasignal.com
- x402.aibtc.com
- x402scan.com
- a2alist.ai
- agentndx.ai
- agoragentic.com
- payanagent.com
- relai.fi
- asterpay.io
- scoutscore.ai
- api.actiongate.xyz
- dialtoneapp.com
- www.inerrata.ai
- wyzecam.com
- renderself.com
- x402.robtex.com
- ethnc.com
- linksys.com
- blurams.com
- shields.io
- umu.se
- vevor.com
- www.schadeautos.nl
- zhipin.com
- zr.ru
- fashionnova.com
- nightcafe.studio
- swann.com
- teltonika.lt
- vevo.com
- wiki.gg
- www.forter.com

## Discovery logic

The scanner starts with `https://{domain}` and builds a `DomainDiscoveryReport`.

### Probe order

For each domain, run these probes with timeouts and structured logging:

1. `GET https://{domain}/.well-known/ucp`
2. `GET https://{domain}/.well-known/ucp.json`
3. `GET https://{domain}/.well-known/commerce`
4. `GET https://{domain}/.well-known/commerce.json`
5. `GET https://{domain}/.well-known/agent.json`
6. `GET https://{domain}/siteai.json`
7. `GET https://{domain}/llms.txt`
8. `GET https://{domain}/openapi.json`
9. `GET https://{domain}/swagger.json`
10. `GET https://{domain}/products.json`
11. `GET https://{domain}/collections/all/products.json?limit=250`
12. `GET https://{domain}/wp-json/wc/store/products?per_page=20`
13. `GET https://{domain}/robots.txt`
14. `GET https://{domain}/sitemap.xml`
15. `GET https://{domain}/`

### Homepage and document parsing

From homepage, robots, sitemap, `llms.txt`, and `siteai.json`, extract candidate URLs that look like:

- OpenAPI or Swagger files.
- UCP files.
- Commerce manifests.
- Agent cards.
- Product feeds.
- API docs.
- Checkout, cart, order, billing, subscription, or pricing endpoints.

For v0.0.1, do a shallow follow only:

- Same host only.
- Maximum 20 discovered URLs per domain.
- Maximum 1 follow depth from the original domain probes.
- Skip binary assets except images referenced by extracted product data.

### API call discovery

For each structured file:

- Parse OpenAPI paths and methods.
- Parse UCP capabilities and endpoint URLs.
- Parse commerce offers and purchase-intent endpoints.
- Parse agent cards and tool URLs.
- Parse x402 or payment-required metadata, including price, method, endpoint, and accepted payment rails.
- Parse Shopify-style `products.json` product and variant data.
- Parse JSON-LD Product objects from homepage HTML.
- Parse OpenGraph product/title/image fallbacks when structured product data is missing.

Each discovered endpoint becomes a `DiscoveredApiCall`:

```swift
struct DiscoveredApiCall {
    let domain: String
    let method: String
    let url: URL
    let source: DiscoverySource
    let capability: String?
    let priceHint: Money?
    let paymentHint: PaymentHint?
    let confidence: Double
}
```

Each product/action becomes a `PurchaseCandidate`:

```swift
struct PurchaseCandidate {
    let id: UUID
    let domain: String
    let merchantName: String
    let title: String
    let description: String?
    let price: Money?
    let imageURL: URL?
    let productURL: URL?
    let sourceURL: URL
    let sourceKind: CandidateSourceKind
    let purchaseStrategy: PurchaseStrategy
    let discoveredAt: Date
}
```

## Background scanner

### Scheduling

- On app launch, scan the first 10 high-signal domains immediately:
  - stableemail.dev
  - renderself.com
  - dialtoneapp.com
  - www.inerrata.ai
  - anybrowse.dev
  - x402.quicknode.com
  - emc2ai.io
  - x402.aibtc.com
  - well-knowns.resolved.sh
  - publish.new
- Then scan the rest of the hard-coded corpus in batches.
- Default cadence: one domain every 60 to 120 seconds.
- Re-scan successful domains every 6 hours.
- Re-scan failed domains with exponential backoff.
- Pause scanning when the user disables the bot.

### Candidate dedupe

Use a stable hash:

```text
sha256(domain + title + price + sourceURL + productURL)
```

Do not show the same candidate twice unless the price changes or the source changes materially.

## Logs

### File locations

Write file logs under:

```text
~/Library/Logs/DialtoneApp Desktop/agent.log
~/Library/Logs/DialtoneApp Desktop/network.log
~/Library/Logs/DialtoneApp Desktop/purchases.log
```

Also keep app data under:

```text
~/Library/Application Support/DialtoneApp Desktop/
```

### Log contents

`network.log` should include one entry per network call:

- Request id.
- Timestamp.
- Domain.
- Method.
- URL.
- Probe type.
- Status code.
- Duration.
- Response content type.
- Response byte count.
- Redirect target if any.
- Parse result.
- Error if any.

`agent.log` should include:

- Scanner start/stop.
- Batch start/end.
- Domain discovery summaries.
- Candidate creation.
- Candidate dedupe decisions.
- Red-dot state changes.
- User approval/rejection events.

`purchases.log` should include:

- Candidate id.
- User auth state.
- Saved-card check result.
- Purchase request id.
- DialtoneApp Network response.
- Merchant response if present.
- Final result.

Never log:

- Card numbers.
- Stripe secrets.
- DialtoneApp auth tokens.
- Payment signatures.
- Set-Cookie values.
- Authorization headers.

### View Log menu option

Add a menu option under the menu bar extra:

- `View Log` opens a `LogWindow`.
- `Reveal Log Files` opens the log directory in Finder.

The log window should have:

- Tabs: `Agent`, `Network`, `Purchases`.
- Search field.
- Domain filter.
- Status filter: all, success, warning, error.
- Clear button for local logs.
- Copy selected lines.

## Menu bar red dot

Replace the static `MenuBarExtra` image label with a custom label:

- Show the favicon-derived menu icon normally.
- Overlay a small red dot at top-right when `unseenCandidateCount > 0`.
- Clear the red dot when the user opens the menu or marks all candidates seen.

The menu should show:

- Current scanning state.
- Unseen candidate count.
- Top 3 candidates.
- `Open DialtoneApp Desktop`.
- `View Log`.
- `Pause Bot` or `Resume Bot`.

## Candidate UI

Add a `Found Items` screen or section.

Each candidate card should show:

- Product photo if available.
- Merchant domain.
- Title.
- Price.
- Description.
- Source type: UCP, products.json, OpenAPI, commerce manifest, x402, JSON-LD, HTML fallback.
- Discovered endpoint or source file.
- Confidence.
- Buttons:
  - `No`
  - `Yes, buy`
  - `Open source`

`No` should:

- Mark the candidate dismissed.
- Keep it in history.
- Log the decision.

`Yes, buy` should:

- Start `PurchaseCoordinator`.
- Log the decision.
- Run auth and saved-card checks before any money moves.

## DialtoneApp auth and saved-card flow

The desktop app needs a real DialtoneApp session before it can know whether the user is logged in or has a saved card.

### v0.0.1 auth path

Implement a desktop login bridge:

1. Desktop app calls DialtoneApp backend to create a short-lived desktop login request.
2. Desktop app opens:

```text
https://dialtoneapp.com/login?desktop_request_id=...
```

3. User completes OTP or Google login in the browser.
4. DialtoneApp redirects to a custom URL scheme:

```text
dialtoneapp-desktop://auth/callback?code=...
```

5. Desktop app exchanges the code for a desktop session token.
6. Store the token in Keychain.

If the app has no valid token, `Yes, buy` opens `https://dialtoneapp.com/login`.

### Saved card check

After login, desktop app calls:

```text
GET https://dialtoneapp.com/api/users/me/network-card
```

If no saved card exists, open:

```text
https://dialtoneapp.com/bot-buyer
```

The UI should say the user needs to add a saved bot-buyer card before DialtoneApp Desktop can buy on their behalf.

## Purchase flow

`PurchaseCoordinator` should make no direct card charges itself. It sends purchase requests to DialtoneApp Network.

### Proposed backend endpoint

Add or use a backend endpoint like:

```text
POST https://dialtoneapp.com/api/users/me/bot-purchases
```

Request:

```json
{
  "candidate_id": "local uuid",
  "domain": "stableemail.dev",
  "title": "Inbox for agent tests",
  "description": "Buy an inbox for testing agent email flows.",
  "price": {
    "amount": "1.00",
    "currency": "USD"
  },
  "source_url": "https://stableemail.dev/openapi.json",
  "product_url": "https://stableemail.dev/...",
  "purchase_strategy": "dialtoneapp_network",
  "discovered_api_call": {
    "method": "POST",
    "url": "https://stableemail.dev/..."
  }
}
```

Backend responsibilities:

- Verify the DialtoneApp user session.
- Verify the user has a saved `bot-buyer` card.
- Verify the requested item is within policy and budget.
- Decide whether the merchant can be purchased by machine.
- Execute the purchase when supported.
- Return a receipt, order id, charge id, subscription id, or fallback reason.

### Result states

The desktop app should handle these backend results:

- `purchased`: show receipt and log success.
- `needs_login`: open `https://dialtoneapp.com/login`.
- `needs_bot_buyer_card`: open `https://dialtoneapp.com/bot-buyer`.
- `needs_browser_checkout`: open returned checkout URL.
- `unsupported_merchant`: explain that the item was discovered but cannot be purchased automatically yet.
- `policy_blocked`: show budget or policy reason.
- `failed`: show error and log request id.

### Public v0.0.1 honesty

Do not claim DialtoneApp Desktop can buy from every scanned domain. Claim it can find products and paid API actions across the corpus, then buy only when DialtoneApp Network has a supported path. For unsupported merchants, the approval flow should still produce a useful debug record and a browser fallback when available.

## Local persistence

Use a small local store under Application Support:

- `domains.json`: hard-coded corpus plus last scan status.
- `discoveries.sqlite`: domain reports, endpoints, candidates.
- `settings.json`: scan enabled, budget, approval settings, dismissed candidates.
- Keychain: DialtoneApp session token only.

Tables:

- `domains`
- `network_calls`
- `discovered_api_calls`
- `purchase_candidates`
- `purchase_attempts`
- `user_decisions`

## Implementation phases

### Phase 1: release foundation

- Confirm bundle id, app name, app icon, menu icon, and signing settings.
- Add hardened runtime and notarization checklist.
- Add app storage directory helpers.
- Add file logger with rotation.
- Add `View Log` menu item and log window.

Done when:

- App launches.
- Menu bar icon appears.
- `View Log` opens.
- Logs write to files.

### Phase 2: domain corpus and scanner

- Add bundled `BotBuyingDomains.json` with all domains above.
- Add `DomainScanner`.
- Add per-probe timeout, response size limits, and redirect handling.
- Add scheduler and pause/resume.
- Add network logs for every call.

Done when:

- The app scans all hard-coded domains over time.
- Each attempted URL appears in `network.log`.
- Failures do not crash the app.

### Phase 3: parsers and candidates

- Implement parsers for:
  - UCP JSON.
  - Commerce manifest JSON.
  - OpenAPI JSON.
  - Shopify `products.json`.
  - WooCommerce store products.
  - JSON-LD Product.
  - Basic OpenGraph fallback.
- Normalize to `DiscoveredApiCall` and `PurchaseCandidate`.
- Add dedupe.

Done when:

- At least stableemail.dev, dialtoneapp.com, anybrowse.dev, well-knowns.resolved.sh, one Shopify-style retail site, and one OpenAPI site produce useful records or useful failure logs.

### Phase 4: notification and candidate UI

- Add `Found Items` view.
- Add menu top 3 candidates.
- Add red dot state.
- Add candidate details with photo fallback.
- Add `No`, `Yes, buy`, and `Open source`.

Done when:

- New candidates trigger the red dot.
- Opening candidates clears the red dot.
- User decisions persist.

### Phase 5: DialtoneApp auth and card gate

- Add Keychain-backed session storage.
- Add desktop login bridge.
- Add `/login` browser fallback.
- Add saved-card check using `/api/users/me/network-card`.
- Add `/bot-buyer` browser fallback.

Done when:

- Logged-out approval opens login.
- Logged-in user with no saved card opens `/bot-buyer`.
- Logged-in user with saved card can continue to purchase request.

### Phase 6: purchase request

- Add `PurchaseCoordinator`.
- Add backend purchase endpoint if missing.
- Send normalized candidate to DialtoneApp Network.
- Display and log result states.

Done when:

- A supported DialtoneApp Network purchase can complete in sandbox.
- Unsupported merchants return an explicit unsupported or browser fallback state.
- Purchase attempts appear in `purchases.log`.

### Phase 7: public release hardening

- Add first-run privacy copy explaining what domains are scanned and where logs are written.
- Add local data reset.
- Add update/check version placeholder.
- Add crash-safe background task handling.
- Add network rate limits.
- Add basic tests for parsers and dedupe.
- Validate no secrets appear in logs.
- Notarize and produce a downloadable build.

## Release acceptance checklist

- App is named `DialtoneApp Desktop` everywhere.
- App can run from the menu bar.
- Hard-coded report domains are bundled.
- Scanner can run for at least 30 minutes without crashing.
- `View Log` works.
- Log files are written to `~/Library/Logs/DialtoneApp Desktop/`.
- Every network call has a log entry.
- At least 10 domains produce successful discovery records or explainable failures.
- At least one product/action candidate appears with title and price.
- Red dot appears when a new candidate is found.
- Candidate card shows image when available.
- `No` dismisses.
- `Yes, buy` opens login when logged out.
- `Yes, buy` opens `/bot-buyer` when logged in with no saved card.
- `Yes, buy` calls DialtoneApp Network when logged in with a saved card.
- Unsupported merchants show a clear unsupported or browser fallback state.
- No card data, secrets, or auth tokens are written to logs.
