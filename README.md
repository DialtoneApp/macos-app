# DialtoneApp Desktop

[DialtoneApp](https://dialtoneapp.com/) helps businesses become AI aware: discoverable by AI systems, readable through clean source pages and markdown mirrors, and ready to move toward agent-mediated sales flows when bots need to do more than quote a page. The public site frames that path as layers: SEO/AEO/GEO and `llms.txt` first, then runtime access through APIs, MCP, or A2A, commerce contracts such as UCP or ACP, and delegated payment authority such as AP2 or scoped tokens.

[DialtoneApp products](https://dialtoneapp.com/products): DialtoneApp Card Registry, DialtoneApp Scan + Support, and DialtoneApp Network. DialtoneApp Desktop is the fourth product.

This repository is the native macOS desktop app for the v0.0.1 public release loop described in [docs/plan.md](docs/plan.md). The release is meant for developers who want to check out the technology, inspect how machine-readable commerce surfaces are discovered, and learn about the practical edges of [bot-to-bot payments](https://dialtoneapp.com/bot-to-bot). The app scans a fixed corpus of bot-buyable domains, records every network probe, extracts product or paid API candidates, and asks the user before starting a purchase flow.

The desktop app also follows the public [dogfood plan](https://dialtoneapp.com/dogfood): prove the two-sided transaction flow in a constrained environment before pretending open-web bot buying is solved. For the broader commerce background, see the [DialtoneApp FAQ](https://dialtoneapp.com/faq).

## Current Status

The first working slice is implemented:

- Native SwiftUI macOS app named `DialtoneApp Desktop`
- Menu bar app with red-dot candidate state
- Hard-coded scan corpus from the April 2026 AI bot buying report
- High-signal domains scanned immediately on launch
- Domain-only discovery, no search engine dependency
- Network logging for each probe
- Candidate extraction from:
  - OpenAPI / Swagger
  - UCP-like JSON
  - commerce manifests
  - agent cards
  - x402-like metadata
  - Shopify `products.json`
  - WooCommerce Store API
  - JSON-LD Product data
  - OpenGraph product metadata
- Found item cards with approve/reject/source actions
- Log window with Agent, Network, and Purchases tabs
- Purchase coordinator scaffold for DialtoneApp login, saved-card gate, and DialtoneApp Network purchase request
- Desktop auth client bridge with login request creation, custom URL callback handling, code exchange, and Keychain session storage
- Environment config for `FRONTEND_URL` and `API_BASE_URL`

Still pending for v0.0.1:

- Backend support for desktop login request creation, code exchange, and browser redirect
- SQLite persistence for reports, network calls, endpoints, and candidates
- Durable scan backoff and 6-hour successful re-scan cadence
- Release signing, archiving, and notarization

## Requirements

- macOS with Xcode 26.x
- Swift 5 target settings from the checked-in Xcode project
- Network access for scanner probes

The app target intentionally has App Sandbox disabled because v0.0.1 writes logs to `~/Library/Logs/DialtoneApp Desktop/` and performs outbound scanner requests.

## Environment

The Debug app uses:

```text
FRONTEND_URL=http://localhost:5173
API_BASE_URL=https://dialtoneapp.com
```

`FRONTEND_URL` controls browser handoffs such as `/login` and `/bot-buyer`. Release is configured with `FRONTEND_URL=https://dialtoneapp.com`; either value can also be overridden with a process environment variable.

## Build

```sh
xcodebuild -project DialtoneApp.xcodeproj \
  -scheme DialtoneApp \
  -configuration Debug \
  -destination 'platform=macOS' \
  build
```

The current build has been verified with that command.

## Run

Open the project in Xcode and run the `DialtoneApp` scheme, or run the debug app from DerivedData after building.

On launch, the app starts scanning these high-signal domains first:

- [stableemail.dev](https://stableemail.dev)
- [renderself.com](https://renderself.com)
- [dialtoneapp.com](https://dialtoneapp.com)
- [www.inerrata.ai](https://www.inerrata.ai)
- [anybrowse.dev](https://anybrowse.dev)
- [x402.quicknode.com](https://x402.quicknode.com)
- [emc2ai.io](https://emc2ai.io)
- [x402.aibtc.com](https://x402.aibtc.com)
- [well-knowns.resolved.sh](https://well-knowns.resolved.sh)
- [publish.new](https://publish.new)

The remaining hard-coded corpus is scanned afterward on a conservative cadence.

## Logs

Logs are written locally under:

```text
~/Library/Logs/DialtoneApp Desktop/
```

Files:

- `agent.log`: scanner lifecycle, candidate creation, dedupe decisions, red-dot state, user decisions
- `network.log`: one structured line per network call
- `purchases.log`: approval and purchase-flow events

The app also creates:

```text
~/Library/Application Support/DialtoneApp Desktop/
```

Use the menu bar option `View Log` to open the in-app log window, or `Reveal Log Files` to open the log directory in Finder.

## Purchase Flow

The desktop app does not charge cards directly.

`Yes, buy` starts `PurchaseCoordinator`, which currently:

1. Checks for a desktop session token in Keychain.
2. Creates a desktop login request and opens the returned browser login URL if no token exists.
3. Checks `GET` [https://dialtoneapp.com/api/users/me/network-card](https://dialtoneapp.com/api/users/me/network-card) when logged in.
4. Opens `{FRONTEND_URL}/bot-buyer` if no saved bot-buyer card exists.
5. Sends supported purchase requests to `POST` [https://dialtoneapp.com/api/users/me/bot-purchases](https://dialtoneapp.com/api/users/me/bot-purchases).

Supported result states are modeled in the app:

- `purchased`
- `needs_login`
- `needs_bot_buyer_card`
- `needs_browser_checkout`
- `unsupported_merchant`
- `failed`

## Project Structure

```text
DialtoneApp/
  ContentView.swift          Main app UI, found-item cards, menu content
  DialtoneAppApp.swift       App entry point, windows, menu bar extra
  DiscoveryScanner.swift     Domain probes, parsing, candidate extraction
  DomainCorpus.swift         Hard-coded v0.0.1 scan corpus
  LocalLogStore.swift        Local file logging and log window data source
  LogWindow.swift            In-app log viewer
  PurchaseCoordinator.swift  Auth/card/purchase-flow scaffold
  ReleaseModels.swift        Money, endpoint, candidate, log, purchase models
docs/
  plan.md                    v0.0.1 release plan and progress notes
  idea.md                    Product notes
```

## Development Notes

- Keep scanner changes conservative; this app is intentionally proving the loop, not arbitrary web automation.
- Do not log card data, auth tokens, payment signatures, `Authorization`, or `Set-Cookie` values.
- Prefer structured manifests and product feeds over brittle HTML scraping.
- Unsupported merchants should produce a useful debug record and a clear browser handoff or unsupported state.
- After scanner changes, restart the running debug app so it uses the newly built code.

## License

See [LICENSE](LICENSE).
