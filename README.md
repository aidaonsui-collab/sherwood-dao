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

`index.html` — the landing page. Fully self-contained (fonts embedded as data URIs, no external requests): night-forest identity, procedural canvas hero, live proof-of-reserve ledger, wanted-poster bond board, watch countdown, and the tokenomics sung as ballads.

```sh
# preview
python3 -m http.server 8143
# → http://localhost:8143
```

Deploys as-is on any static host (Vercel, GitHub Pages).

---

*SherwoodDAO is an independent protocol concept built for Robinhood Chain and is not affiliated with Robinhood Markets, Inc.*
