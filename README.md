# SherwoodDAO · $WOOD

**A treasury-backed reserve currency.** OlympusDAO (2021) reimagined with the 2025 seatbelts built in from day one — taken from the market makers, given to the holders. (🏹,🏹)

**Status: protocol Phase 1 in progress.** Foundry contracts live under `contracts/`. The static site is still a concept UI (demo wallet only). Nothing is production-deployed; figures on the pages remain illustrative until addresses are wired.

## Protocol (Phase 1)

| Module | What it is |
| --- | --- |
| **WOOD** | Reserve currency ERC20; mint only via Treasury from excess RFV |
| **Treasury** | Holds USDG / SGOV / equities / POL; reports `totalReserves`, `excessReserves`, `backingPerWood` |
| **Camp** | Stake WOOD → sWOOD shares; 8-hour *watches* mint from excess |
| **Heist** | Bond a quote asset → vest WOOD at ≥ RFV price; 10% protocol mint to Treasury |
| **Vault** | Borrow USDG at 95% of **backing** (not spot), 0.50% APR → Treasury |
| **RangeBound** | Skeleton: bid/ask when spot leaves the band around backing |
| **Authority** | Central roles (governor / guardian / minters) |

See **[PROTOCOL.md](./PROTOCOL.md)** for formulas, roles, and deferred work.

```sh
cd contracts
forge test -vv
forge build --sizes
```

```sh
# local deploy (anvil)
anvil &
cd contracts && forge script script/DeployLocal.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
```

Live on Robinhood Chain testnet (46630) — addresses and a full exercise log in
**[DEPLOYMENTS.md](./DEPLOYMENTS.md)**.

## Design (product)

| Olympus 2021 | Sherwood |
| --- | --- |
| Treasury of stablecoins farming DeFi yield | Treasury of tokenized T-bills (SGOV), USDG, equities, and protocol-owned liquidity — backing computed on-chain from live balances × `uiMultiplier` × oracle price |
| Bonds for DAI / OHM-DAI LP | **The Heist** — bonds accept USDG, SGOV, tokenized stocks, and WOOD/USDG LP |
| 8-hour rebase epochs | **The Camp** — same cadence, epochs are *watches*; APY shown next to its honest dilution reading |
| Price premium unanchored → -95% | **Range-Bound Stability from launch** — treasury bids below the band with reserves, sells above it |
| Cooler Loans bolted on as wind-down | **The Vault at launch** — borrow USDG at 95% of backing, 0.50% fixed, no price liquidations |
| (3,3) | (🏹,🏹) |

## Frontend (concept UI)

Two self-contained HTML files (no build step):

- **`app.html`** — product dashboard (Overview · WOOD · Heist · Vault · Council). Demo mode only.
- **`index.html`** — marketing landing.

```sh
python3 -m http.server 8143
# → http://localhost:8143/app.html
# → http://localhost:8143/index.html
```

Wiring the app to live ABIs is a follow-up after Phase 1 contracts stabilize.

---

*SherwoodDAO is an independent protocol concept and is not affiliated with Robinhood Markets, Inc.*
