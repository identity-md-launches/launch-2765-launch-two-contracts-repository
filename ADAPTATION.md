# Adaptation for the Robinhood Chain launch (ConditionalsV2)

Launch kind `evm_contracts`, chain 4663, two contracts in this order:

1. `src/ConditionalsV2.sol:ConditionalsV2`, constructor `(address owner = $owner, IERC20 imd =
   0x5f7bb59365ce557c26dbcaa4ee9d39a4b95b7127, IIntake intake = 0xa43e6f75ee006411f79ac1c84120606c2330de82,
   address oracleSigner = 0x5598aa9146215bc13eb26f2c692ad1461fd32982, address feeRecipient =
   0x63bcf2d1483c7628d7d53704ff9c8199dc28d907)`.
2. `src/ConditionalsZap.sol:ConditionalsZap`, constructor `(ConditionalsV2 conditionals = $contract:ConditionalsV2,
   IPoolManager poolManager = 0x8366a39cc670b4001a1121b8f6a443a643e40951, IERC20 imd = 0x5f7b…7127, IERC20 usdg =
   0x5fc5360d0400a0fd4f2af552add042d716f1d168)`.

(The previous version of this file covered the v1 launch 2278, `legacy/`. It is still in git history.)

## Launch rules: no change needed

- Both constructors were already right for the factory: nonpayable, 5 and 4 static `address` arguments, no external
  calls, no requirement that any address has code. The owner is the `owner_` argument (`Ownable(owner_)`), never
  `msg.sender` or `tx.origin`. ConditionalsZap has no owner.
- No token, mint, pause, freeze, blacklist, proxy, initializer, DELEGATECALL, CALLCODE or SELFDESTRUCT. Every
  `transferFrom` is from `msg.sender`. No `abi.encodePacked`, and no Yul. Every library call is internal, so the
  bytecode needs no linking. `bytecode_hash = "none"` was already set.
- Rehearsed: both contracts deployed by CREATE2 in one test on an empty chain (chain id 4663) with the brief's
  arguments. The runtimes are 24,433 bytes (ConditionalsV2) and 3,646 bytes (ConditionalsZap), both under 24,576,
  and no forbidden opcode is reachable.

No launch.json is written here: the manifest step owns it. `foundry.toml`, remappings, `lib/` and lockfiles are
untouched.

## Audit findings

Each finding was reproduced against the code as it arrived, using the audit's proofs and the new tests below. Each
new test fails on the original `src/ConditionalsV2.sol` and passes on this one.

### 7011982a (low): `exit` underflowed `Market.sets`. Reproduced and fixed

The proof fails on the original with panic 0x11 at `m.sets -= sets_`. A complete set bought from the maker one outcome
at a time is backed by the maker, not by `sets`. `exit` now takes the redeemed sets from `sets` while they last.
The rest are redeemed from the maker: every `q[i]` and `makerBalance` move down by the same amount. C(q) moves
down by exactly that amount, so prices do not change and `makerBalance >= C(q)` still holds. `makerBalance` cannot
underflow because the account holds those shares, so `q[i] >= fromMaker` for every i. The proof now passes (Bob
gets exactly 1 IMD).

- `src/ConditionalsV2.sol`: `exit`.
- `test/ConditionalsV2.t.sol`: `test_audit_exitRedeemsSetsBoughtFromTheMaker` (the audit's scenario, with
  unchanged prices and solvency checked) and `testFuzz_audit_exitAnyCompleteSet`. The fuzz test also settles to each
  outcome and checks that the contract pays everything out.

### 913c99ee (low): sells could price a world at zero. Reproduced and fixed

The proof fails on the original with `DivWadFailed`. The problem was wider than the audit described. With world 0 at
zero, every buy and every stake in either world reverted `PriceLimit`, because `_checkSpread` is global, until
someone sold world-1 shares. `_sell` now runs the same `_checkSpread` as buys and stakes. Every trade therefore
keeps `max q - min q <= 20 b`, and every price stays above about 2e-9.

The original comment's reason for skipping the check was that nobody should be stopped from leaving. To keep that
for `exit`, it sells each leftover outcome only up to `_sellRoom`, the amount that keeps the spread, and skips
amounts below `MIN_TRADE`. The shares beyond that are worth under about 2e-9 IMD each. They stay with the account,
and a later `exit` or `sell` can sell them once the market moves. `sell` reverts `PriceLimit` only for a sell that
would break the bound. A smaller sell goes through.

Skipping dust below `MIN_TRADE` also removes the audit's side note (b84bec92) that a dust holding made `exit` revert
`TradeTooSmall`.

The held proof cannot pass against this fix: it needs `sell(id, 0, 24e18, 0)` to succeed. On this tree it stops
there with `PriceLimit`, which is the fix working. Its scenario is covered below.

- `src/ConditionalsV2.sol`: `_sell` (spread check), `exit` (sells what fits), new `_sellRoom`.
- `test/ConditionalsV2.t.sol`: `test_audit_sellCannotPriceAWorldAtZero` (the audit's scenario). The dump reverts and a
  sell inside the spread works. `conditionals`, `quoteStake` and a stake on world 0 all work afterwards.
  `test_audit_exitSellsWhatFitsTheSpread`: `exit` does not revert at the bound, keeps the unsellable shares, and a
  second exit closes the position.
- `test/ConditionalsV2Invariant.t.sol`: `invariant_spreadBounded`, which also calls `conditionals`. On the original
  code the handler breaks it on its own.
- `README.md`: "Spread bound".

### b37b3ab1 (low): a live price above the snapshot stranded the market. Reproduced and fixed

The proof fails on the original with `PriceNotMet`. `_askPrice` now pays the Intake's live price whenever it is
non-zero and at most `MAX_PRICE`, the 10 IMD bound that already applies to configurations. The existing `_ask` path
does the rest: the budget pays while it covers the price, then the caller pays, exactly as a retry already
charges the caller. The unspent budget still returns to the creator at settlement or void. An unreadable,
zero or above-10-IMD live price falls back to the snapshot, as before. The proof now passes.

This reverses v1's choice (d2cd6ea6 in the previous file) for ConditionalsV2. The audit reproduced it as a defect:
with the old behaviour, a protocol price change voids every open market. Under the new one, the caller of
`requestResolution` can be charged up to `MAX_PRICE` per ask. The question format, the body, the callback checks and
the oracle flow are unchanged.

- `src/ConditionalsV2.sol`: `_askPrice` and its comment.
- `test/ConditionalsV2.t.sol`: `test_audit_askPaysALivePriceAboveTheSnapshot` (0.6 IMD: the budget pays one ask and
  the caller the other, both are answered and settle, and 0.4 IMD of budget returns). Also
  `test_audit_askNeverPaysAboveMaxPrice` (10 IMD + 1 is refused, 10 IMD is paid). The existing
  `test_oracle_budgetSpentThenReturned` (a lower price) is unchanged and passes.
- `README.md`: "Price changes".

### 34e17b7a (low): each market pins its signer. Confirmed, not changed

Confirmed by reading the code (no audit proof was supplied): `onOracleResult` verifies only against `m.oracle.signer`,
and that is snapshotted at creation. A market created under signer S1 therefore refuses an answer signed by S2
after a rotation, and it ends in a void.
This is what the brief requires: the answer needs "an EIP-712 signature … from the market's oracle signer". The owner
"cannot touch trades, answers or open markets". If a rotated signer applied to open markets, the owner could settle
them with a key of its choice after 3 days. Rotation without stranding markets is still possible:
`SignatureChecker` accepts an ERC-1271 signer, so a market created with the protocol's signer registry as its signer
follows the registry's rotations.

### b84bec92 (info): coverage. Nothing to fix

The only note in it that changed behaviour (dust below `MIN_TRADE` blocking `exit`) is handled under 913c99ee. The
other note, that `a.requestId` is not consumed, was not changed. Retries are at least `RETRY_DELAY` apart, so two
asks never share a question hash and no replay is possible.

## Size

ConditionalsV2's runtime went from 24,148 to 24,433 bytes (limit 24,576), with `optimizer_runs = 1` as configured.

## Checks run

- `FOUNDRY_FUZZ_SEED=0x5d83227fee2096f4e9e1dfcdf39851d7320e2b9f2ba8471b17718ec60e88cbc5 forge test`: 57 tests pass.
  That is 41 unit and fuzz tests, 1 invariant suite, 6 question and live-API hash vector tests, and 4 oracle
  conformance tests. The 5 fork tests return without an RPC.
- `FORK_ROBINHOOD=1 forge test --mc Fork`: all 5 fork tests pass against Robinhood Chain (the real Intake takes
  the asks, and the zap stakes with ETH and USDG and honours `minImd`).
