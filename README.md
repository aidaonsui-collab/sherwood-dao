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

`index.html` — one self-contained file (Playfair Display, Instrument Sans and Geist Mono embedded as data URIs, no external requests), two views, mirroring how OlympusDAO splits `olympusdao.finance` (marketing) from `app.olympusdao.finance` (the dashboard):

- **Marketing** (default view) — a cinematic WebGL night-forest hero, protocol stats strip, feature sections (Protocol-Owned Liquidity, the Vault, Range-Bound Stability, Governance), participate cards, the Olympus-vs-Sherwood reckoning table, the Ballads, and an FAQ. Every CTA funnels into the app.
- **App** (`Enter the Forest`) — an Olympus-style icon rail + sub-panel shell: **Overview** (dashboard — price/backing chart, sparkline stat cards, feature summary cards, a live activity feed, plus a Treasury sub-tab with the full proof-of-reserve table), **WOOD** (balance, staking), **Heist** (bonds), **Vault** (loans), **Council** (governance, plus a Charter sub-tab). Client-side hash routing; a deep link straight to an app route (e.g. `#vault`) skips the marketing view entirely.

"Connect Wallet" opens an honest gate — SherwoodDAO is a concept, nothing is deployed, no wallet can truly connect — with an opt-in "enter as a ranger" demo mode (persisted in `localStorage`) that unlocks a simulated stake flow. Every demo action resolves to a toast, never a transaction.

```sh
# preview
python3 -m http.server 8143
# → http://localhost:8143
```

Deploys as-is on any static host (Vercel, GitHub Pages).

---

*SherwoodDAO is an independent protocol concept built for Robinhood Chain and is not affiliated with Robinhood Markets, Inc.*
