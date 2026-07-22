# SherwoodDAO Protocol — Phase 1

**Status:** implementation in progress (Foundry). Nothing is production-deployed.

A treasury-backed reserve currency (`WOOD`) with Olympus-shaped seatbelts from day one: excess-only minting, 8-hour watches, bonds (Heist), backing-floor loans (Vault), and a range-bound stability skeleton.

## Module map

| Module | Contract | Status |
| --- | --- | --- |
| Roles | `Authority` | Live |
| Currency | `WOOD` | Live |
| Staked shares | `sWOOD` (deployed by Camp) | Live |
| Reserves / RFV | `Treasury` | Live |
| Stake + watches | `Camp` | Live |
| Bonds | `Heist` | Live (single market) |
| Borrow vs backing | `Vault` | Live (core math) |
| Band ops | `RangeBound` | Skeleton (band gating + hooks) |
| Oracles | `MockOracle`, `ManualOracle` | Bootstrap |
| Council | — | Deferred |

## Backing formula

All values in 18-decimal USD units (“WAD”).

```
assetValue(token) = balance_normalized_18 * oraclePrice * uiMultiplier / 1e36
totalReserves     = Σ assetValue(token)   for enabled assets
excessReserves    = max(totalReserves − WOOD.totalSupply, 0)
backingPerWood    = totalReserves * 1e18 / totalSupply   (or 1e18 if supply = 0)
```

**Invariant:** Camp rebases and Heist claims may only mint WOOD while `amount ≤ excessReserves`.  
**Target:** 1 WOOD is backed by ≥ $1 of risk-free value (RFV). Premium to RFV is market opinion; RFV is the contract fact.

`uiMultiplier` (≤ 1e18) haircuts non-cash assets (e.g. equities at 0.9e18).

## The Camp (staking + watches)

- Stake WOOD → mint **sWOOD shares** at current index.
- `wood = shares * index / 1e9`.
- Every **8 hours** anyone may call `rebase()`:
  - `reward = stakedWood * rewardRateBps / 10_000` (governor-set; default 10 bps = 0.10%/epoch)
  - Cap reward by `excessReserves`
  - Mint reward WOOD into Camp; raise `index` so all stakers share pro-rata
- sWOOD is **non-rebasing** (standard ERC20). UI should show `Camp.woodBalanceOf(user)`.

## The Heist (bonds)

Single market in Phase 1:

- Pay quote asset (e.g. USDG) → quote lands in **Treasury** (raises reserves)
- Vest WOOD over `vestingTerm` with `controlVariable` (e.g. 1.05e18 ≈ 5% discount)
- WOOD minted from excess **on claim**, not on deposit

## The Vault

- Collateral: sWOOD shares  
- Debt asset: USDG (from Treasury reserves; Vault holds `RESERVE_SPENDER`)  
- Max LTV: **95% of RFV** (`backingPerWood * woodValue`), **not** spot  
- Interest: **0.50% APR** fixed, continuous on touch  
- No price liquidations in Phase 1 (guardian/owner operational path only)

## Range-bound stability

- Band around `backingPerWood`: default 95%–105%  
- Spot from `woodSpotOracle`  
- `executeBid` / `executeAsk` guardian-gated; real DEX routing deferred  

## Roles (`Authority`)

| Role | Used by |
| --- | --- |
| `GOVERNOR` | Asset registry, rates, markets, band |
| `GUARDIAN` | RangeBound ops, emergency posture later |
| `RESERVE_DEPOSITOR` | Privileged treasury deposits |
| `RESERVE_SPENDER` | Vault, RangeBound withdrawals |
| `REWARD_MANAGER` | Camp (and bootstrap minter) |
| `BOND_MANAGER` | Heist |
| `WOOD_MINTER` | Treasury (only path that mints WOOD) |

Owner of Authority is the bootstrap admin; later transfer to Council.

## Explicitly deferred

- On-chain Council / sWOOD voting  
- Real Robinhood Chain RWA oracles  
- Multi-market Heist, LP bonds  
- Keeper bots for RBS  
- Upgradeable proxies  
- Frontend wallet wiring  

## Commands

```sh
cd contracts
forge test -vv
forge build --sizes
# local stack
anvil &
forge script script/DeployLocal.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
```
