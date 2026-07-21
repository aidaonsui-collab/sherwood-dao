# SherwoodDAO · $WOOD

**A treasury-backed reserve currency for Robinhood Chain.** OlympusDAO (2021) reimagined with the 2025 seatbelts built in from day one — taken from the market makers, given to the holders. (🏹,🏹)

**Status: concept.** Nothing is deployed; every figure on the page is illustrative.

## The design

| Olympus 2021 | Sherwood |
| --- | --- |
| Treasury of stablecoins farming DeFi yield | Treasury of tokenized T-bills (SGOV), USDG, RH-chain equities, and protocol-owned liquidity — backing computed on-chain from live balances × `uiMultiplier` × oracle price |
| Bonds for DAI / OHM-DAI LP | **The Heist** — bonds accept USDG, SGOV, tokenized stocks, and WOOD/USDG LP |
| 8-hour rebase epochs | **The Camp** — same cadence, epochs are *watches*; APY shown next to its honest dilution reading |
| Price premium unanchored → -95% | **Range-Bound Stability from launch** — treasury bids below the band with reserves, sells above it |
| Cooler Loans bolted on as wind-down | **The Vault at launch** — borrow USDG at 95% of backing, 0.50% fixed, no price liquidations |
| (3,3) | (🏹,🏹) |

## This repo

Two self-contained files (Playfair Display, Instrument Sans and Geist Mono embedded as data URIs, no external requests) — split the way OlympusDAO splits `olympusdao.finance` (marketing) from `app.olympusdao.finance` (the dashboard):

- **`index.html` — the app** (served at the root). A clean, Apple-caliber product dashboard: a single sidebar (Overview · WOOD · Heist · Vault · Council), and per section — **Overview** (price-vs-backing chart, a row of stat cards with trend indicators, feature cards, a recent-activity feed, plus a Treasury sub-tab with the full proof-of-reserve table), **WOOD** (balances + a stake/unstake widget and the rebase watch-face timer), **Heist** (bond "wanted poster" cards), **Vault** (a borrow-against-backing widget), **Council** (governance empty-state + draft proposals, plus a Charter sub-tab). Client-side hash routing (`#overview`, `#wood`, `#heist`, `#vault`, `#council`, sub-routes like `#overview/treasury`). Links to the landing via "View the landing page ↗".
- **`index-landing.html` — the marketing landing**. The cinematic WebGL night-forest hero (moonlit sky, pine ridges, levitating golden arrow, runed oak), the Olympus-vs-Sherwood reckoning, and the Ballads.

"Connect Wallet" opens an honest gate — SherwoodDAO is a concept, nothing is deployed, no wallet can truly connect — with an opt-in demo mode (persisted in `localStorage`) that unlocks simulated stake/borrow flows. Every demo action resolves to a toast, never a transaction.

The app presentation was designed via the Claude Design app to a "make it look like a premium Apple app, not a crypto template" brief.

```sh
# preview the app
python3 -m http.server 8143
# → http://localhost:8143  (app)
# → http://localhost:8143/index-landing.html  (marketing landing)
```

Deploys as-is on any static host (Vercel, GitHub Pages).

---

*SherwoodDAO is an independent protocol concept built for Robinhood Chain and is not affiliated with Robinhood Markets, Inc.*
