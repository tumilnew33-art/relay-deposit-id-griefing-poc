# PoC: Deposit ids are not unique on-chain; a 0-value front-run can grief a victim's deposit credit

Relay bug bounty report R-06. Run with Foundry (tested with forge 1.9.0):

```
forge test -vv
```

No setup, no network, no fork needed. All dependencies are vendored under `lib/`
(the depository contracts are the unmodified sources from
`relayprotocol/relay-depository` at commit `458a64c`).

## What it proves (4/4 tests pass)

- **R-06** `test_duplicateDepositId_bothSucceed`: a 0-value deposit and a real
  deposit sharing the SAME id (and same depositor) both succeed on-chain and
  emit indistinguishable deposit events. `RelayDepository` never tracks used
  ids — `id` exists only as an event field — so an attacker can front-run a
  victim's mempool deposit with a 0-value deposit reusing the victim's id at
  gas-only cost. If downstream order-linking dedupes by id, the victim's real
  deposit is ignored and its funds sit in the depository uncredited until
  Relay intervenes manually.
- The other three tests (`test_fakeDeposit_noOpToken`,
  `test_fakeDeposit_eoaToken_reverts`, `test_fotDeposit_overcredited`)
  demonstrate related deposit-accounting behavior: `depositErc20` emits the
  nominal amount without verifying receipt (a no-op token yields a deposit
  event for tokens never received; a 10%-fee token yields an event claiming
  1,000 while only 900 arrive). This is informational only (I-01) and is NOT
  part of the R-06 report — the EVM attestor credits Transfer events, not
  deposit-event amounts, so there is no fund-loss path there.

## Caveat

The EVM attestor itself does NOT dedupe by id — it keys messages on
`(chainId, transactionId, logIndex)` and emits BOTH the 0-value and the real
deposit messages (verified in
`relay-oracle/src/services/attestation/vm/ethereum-vm/index.ts`). The griefing
therefore depends on DOWNSTREAM id-based order linking, which was NOT verified
from the repos. The on-chain half (duplicate ids accepted) is proven by this
PoC; the off-chain half is a stated condition, not a verified fact.

## Setup notes

- `via_ir = true` and `evm_version = "cancun"` are required (copied from the
  original PoC configuration).
- Local test only; nothing here touches mainnet.
