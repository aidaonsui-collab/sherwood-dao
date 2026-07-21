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

`index.html` — the app. Fully self-contained (Playfair Display, Instrument Sans and Geist Mono embedded as data URIs, no external requests): a sidebar-routed shell (The Greenwood: Enter the Forest · Camp · Heist · Vault · Treasury — The Lore: Ledger · Governance · Docs), hash-based client-side routing, and a cinematic WebGL night-forest hero on the landing panel — moonlit sky, layered pine ridges, a levitating golden arrow before the great rune-carved oak. Degrades gracefully to a 2D canvas / SVG hero where WebGL is unavailable.

"Connect Wallet" opens an honest gate — SherwoodDAO is a concept, nothing is deployed, no wallet can truly connect — with an opt-in "enter as a ranger" demo mode (persisted in `localStorage`) that unlocks a simulated stake flow. Every demo action resolves to a toast, never a transaction.

```sh
# preview
python3 -m http.server 8143
# → http://localhost:8143
```

Deploys as-is on any static host (Vercel, GitHub Pages).

---

*SherwoodDAO is an independent protocol concept built for Robinhood Chain and is not affiliated with Robinhood Markets, Inc.*
