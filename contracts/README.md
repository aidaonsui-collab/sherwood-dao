# SherwoodDAO contracts

Foundry package for the Phase-1 protocol. See root [PROTOCOL.md](../PROTOCOL.md).

```sh
forge test -vv
forge build --sizes
forge script script/DeployLocal.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
```

## Layout

```
src/
  Authority.sol      # roles
  WOOD.sol           # reserve currency
  sWOOD.sol          # Camp share token
  Treasury.sol       # RFV reserves
  Camp.sol           # stake + 8h watches
  Heist.sol          # bonds
  Vault.sol          # borrow vs backing
  RangeBound.sol      # band skeleton
  interfaces/
  oracles/
test/Sherwood.t.sol
script/DeployLocal.s.sol
```
