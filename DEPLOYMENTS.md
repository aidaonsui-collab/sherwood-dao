# Deployments

## Robinhood Chain testnet (46630) — Phase 1, 2026-07-22

First live deploy off `protocol-phase1`. Self-contained: reserve assets are self-minted mock
tokens (`tUSDG`, `tSGOV`, permissionless `mint`), not any shared/canonical testnet token — this
deploy has zero dependency on and zero effect on other testnet state. Deployer was a
fresh, disposable key funded from the public faucet (0.01 ETH); nothing beyond gas was ever at
stake.

Deploy script: `contracts/script/DeployTestnet.s.sol`.

```sh
PRIVATE_KEY=0x... forge script script/DeployTestnet.s.sol --tc DeployTestnet \
  --rpc-url https://rpc.testnet.chain.robinhood.com --broadcast
```

### Addresses

| Contract | Address |
| --- | --- |
| Authority | `0x84f3aea02f63D4272EDA475b5308d532055e3A4c` |
| WOOD | `0xDd0C94167DBf92Fad6Cb076F750e8E9dB3225EC5` |
| sWOOD | `0x3F499A0d82b06F7e45f6ADA42eA6d101CA162D8C` |
| Treasury | `0x33796D7E65aDA81510441fFE3E5056Fdc84ac4f9` |
| Camp | `0x675b3bBbB4F90Be7eccbf6C6795A7792fCB7A856` |
| Heist | `0x0eC7e6DA5Cb84b245291144F715073109cb69f4a` |
| Vault | `0xffCC019E3c0FA090659a6471e3c48Eb219B893b6` |
| RangeBound | `0x691546e00B48Cce6B5deA7B23bD4A0850A115Cfa` |
| tUSDG (mock reserve) | `0x0ACb986f972da2eB5D1a4Bc05c9bEb78C5F8CF9d` |
| tSGOV (mock reserve) | `0xD2c9916B59d12577dA85672512c47C96eef25ceF` |
| tUSDG oracle | `0x6523536210B6DD00EcE82dE60D1C6FbD5d52b133` |
| tSGOV oracle | `0xD8053D914bc551dc9d31E8247BaA934836D80761` |
| WOOD spot oracle (RangeBound) | `0x9DF0da46355fe0Ee02037adF8E4c3954ad4E6047` |

Chain ID 46630 · RPC `https://rpc.testnet.chain.robinhood.com` · initial backing $20.00/WOOD
(200,000 reserves / 10,000 WOOD bootstrap).

### End-to-end exercise

Every mechanism was exercised for real on-chain (not just under `forge test`'s cheatcodes) —
51 transactions, all confirmed, ground-truth-verified against live contract reads after each
step rather than trusted from tx receipts alone:

1. **Camp** — stake 3,000 WOOD → 3,000 sWOOD (1:1, fresh index).
2. **Heist** — bond 500 tUSDG at 2× the RFV floor, 2-minute vest (shortened for this exercise
   only, to prove the *real-time* vesting → claim path rather than relying on `vm.warp`).
3. **Treasury oracle-staleness guard** (Phase-1 review fix) — set `maxPriceAge=30s`, waited 35s
   past it, confirmed `totalReserves()` reverts `StalePrice`; refreshed both oracles, confirmed
   reads succeed again; reset to `0` (disabled, the shipping default).
4. **Vault** — deposited 1,000 sWOOD collateral, borrowed 15,000 tUSDG (well inside the 95% LTV
   headroom at $20 backing).
5. **RangeBound** — set WOOD spot to $10 (below the $17.62 lower band), guardian `executeBid`
   pulled 50 tUSDG from Treasury.
6. **Crashed the tUSDG oracle** to $0.03 → Treasury reserves collapsed → backing fell to ~$5.40 →
   the Vault position from step 4 became underwater (`maxBorrowFor` ≪ outstanding debt).
7. **`Vault.seize`** (the Phase-1 review fix — there was no recovery path before) — closed the
   underwater position, unstaked the 1,000 sWOOD collateral to WOOD, sent it to the Treasury.
   **`Treasury.burnWood`** burned it, restoring backing. (First attempt in the exercise script hit
   a client-side bug — see below — re-run confirmed correct: supply dropped by exactly the
   recovered amount, Treasury's WOOD balance returned to 0.)
8. **Heist.claim** — after the 2-minute vest elapsed, claimed the fully-vested bond: user WOOD +
   10% protocol share minted to Treasury.
9. **Camp.unstake** — partial unstake, WOOD returned 1:1.

Final state cross-validated exactly against hand-computed expectations at every step (backing,
excess reserves, LTV caps, bond payout, all matched to the wei).

**Not exercised live:** `Camp.rebase()` (`EPOCH_LENGTH` is a hard-coded 8h constant — can't be
shortened for a test run without deploying different code than what ships) and re-bonding's
auto-claim (only bonded once here). Both are covered by passing local `forge test` cases; this
run was about proving real-network wiring and gas behavior, not re-proving unit-level logic
already covered.

**Process note:** `cast call`'s default `(uint256)` output is `"<value> [<sci-notation>]"`
(e.g. `"1000000000000000000000 [1e21]"`). Capturing that whole string into a shell variable and
feeding it straight to `cast send` fails to encode as calldata — silently, with no on-chain
trace (the client never broadcasts). Always strip to the raw number first
(`awk '{print $1}'` or equivalent) before round-tripping a `cast call` result into a `cast send`.

Full transaction log (all 51 hashes): kept locally, not committed (ephemeral testnet run, not
meant to be a permanent artifact — the addresses above are the durable record).

---

*SherwoodDAO is an independent protocol concept and is not affiliated with Robinhood Markets, Inc.*
