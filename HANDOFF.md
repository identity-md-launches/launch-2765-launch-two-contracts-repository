# Handoff: Conditionals

Last updated: 2026-10-31. Separate entry from GAMMA (`~/projects/imd`). GitHub and Vercel: **UgwujaGeorge** (not
haileymarshall). Push with `gh auth token --user UgwujaGeorge`; do not switch the active gh account.

## Session 2026-10-31: domain live, frontend adjustments

- **https://conditionals.xyz is live** (bought by the user, renews at $13/yr). `www` and `conditionals-bay.vercel.app`
  308-redirect to it. Step 1 of the list below and the domain purchase are done.
- Wallet funded: **16 IMD, ~0.0015 ETH** (read onchain 2026-10-31). Covers the 15.5 IMD high-end budget.
- Frontend adjustments shipped: hero and fork fit a short screen (user views at ~1253x550, Windows 150% scaling; test
  there), oracle chip under the title, fee card, hackathon link and contract links removed, "Built on IMD" replaced by
  a short "IMD" section. The user does not want the site to explain routing or how the app uses IMD. The user may send
  more adjustments.
- **New v2 requirement:** bet with ETH or stablecoins; the contract swaps to IMD in the same transaction, with a price
  limit, and pots, refunds and payouts stay in IMD (payouts in IMD is our assumption; the user has not objected). The
  site names ETH and USDG with a "Coming with v2" chip: **remove the chip in `Sections.tsx` only when it works**.
- Routes seen on DexScreener 2026-10-31: IMD/ETH ~$234k liquidity, IMD/USDG ~$25k, IMD ~$3.60. No usable USDC or USDT
  route found. Launch with ETH and USDG. Several tokens are named USDG: confirm the real address and allowlist only it.
- Still open: deploy route (IMD launch recommended) and the 5 market topics.

## Session 2026-10-29: domain, v2 liquidity, first markets

The user wants three things: (1) move the site to **conditionals.xyz**, (2) implement the v2 liquidity fixes from
`frontend/public/docs/conditionals-v2-liquidity.pdf`, (3) create **5 markets** on the frontend, seeded by the user.

### State found at the start

- v1 live at `0xc8cc656b71dd77ae1e29b0bc7890edd110e73255` (IMD launch 2278); `marketCount()` = 1.
- Launch wallet `0x63BCf2d1483c7628d7D53704ff9c8199Dc28d907`: **0 IMD, ~0.0000006 ETH**. It cannot pay gas, a
  launch or markets until the user funds it.
- Local `main` is 1 commit ahead of origin (`474d1ad`, the v2 PDF link on /docs), not pushed yet.

### Done this session

- Checked conditionals.xyz: available on Vercel, $1.99 first year, $13/yr renewal. User approved buying it there.
- `vercel domains buy` refuses to run for an agent (`purchase_requires_user`). **The user must buy it themselves**:
  `! vercel domains buy conditionals.xyz --global-config ~/.vercel-george --scope ugwujageorges-projects`
  (or the Vercel dashboard, Domains, as UgwujaGeorge).
- Uncommitted edits: `frontend/src/app/layout.tsx` adds `metadataBase` and `openGraph.url` =
  `https://conditionals.xyz`; `frontend/src/app/docs/page.tsx` "Try it at" link text now reads conditionals.xyz.

### Decisions agreed with the user (explained to them in plain language)

- **v2 = LMSR market maker, no vault for now** (PDF option "seed small"). Four outcomes per market (world A/B x
  YES/NO) in one pot; prices from the formula from the first trade; early exit by selling; one stake spans both worlds.
- **Seed is optional and small.** The seed is neutral (the creator does not pick a side); max loss per market = the
  seed. The user will seed 5 markets with **1-2 IMD each, 5-10 IMD total at risk**, and does not want to lose more.
  Without the vault, the 1% LP fee goes to the market's seeder. Markets without a seed fall back to v1 pool style
  (or must be blocked: decide in the build; simplest is a small minimum seed).
- This means **min b must drop well below the PDF's 10 IMD**: seed = b ln 4, so 1-2 IMD seed is b ~0.72-1.44 IMD.
  The user was told these markets are thin (a 1 IMD trade moves the odds a lot). Update the PDF parameters/docs.
- Oracle cost is separate and always spent: ~1 IMD per market (two questions x 0.5 IMD), ~5 IMD for 5 markets.

### Still open (ask the user)

1. **Deploy route for v2**: new IMD launch (0.5 IMD, swarm audit, parks and loses the 0.5 IMD on any medium/high
   finding) vs direct deploy from the wallet (no audit, not an IMD launch). Not answered yet.
2. **The 5 market topics** ("If [condition], will [outcome]?") or let Claude propose them.
3. **Funding**: wallet needs ETH for gas + ~5 IMD oracle + 5-10 IMD seeds (+0.5 IMD if IMD launch). `launch/buy-imd.sh`
   buys IMD with ETH.
4. What "adjustments to conditionals" means beyond the above (the user mentioned it; not specified yet).

### Next steps, in order

1. After the user buys the domain: `vercel domains add conditionals.xyz` (and `www.conditionals.xyz`) on project
   `conditionals` with the George config; commit the two edits (`chore(frontend): move the site to conditionals.xyz`),
   push `main` with the UgwujaGeorge token (Vercel redeploys), check https://conditionals.xyz. Update this file.
2. Build `ConditionalsV2.sol` per the PDF minus the vault: complete sets, LMSR (Solady expWad/lnWad, log-sum-exp,
   maker-favoured rounding), buy/sell with slippage bounds, `stakeConditional` router, cost-basis void, fees
   200 bps (LP to seeder / burn / builder), oracle flow copied from v1 unchanged. Low `MIN_B`. Tests for invariants
   I1-I8, fuzz, fork test against the live Intake. Keep v1's audit lessons (dust/fee cap, world B answer bug).
3. Frontend: switch to v2 ABI, show live prices per outcome, buy/sell, seed field on create, keep v1 markets readable.
4. Deploy by the chosen route (for an IMD launch: `POST /requests/check` first, then `launch/pay.sh`).
5. Create the 5 markets from the funded wallet with 1-2 IMD seed each; verify on the site.

## Where we stopped

- Contract done and tested: `src/Conditionals.sol`. 44 tests pass (unit, fuzz, 3 invariants); the fork test passes
  against the real Robinhood Chain Intake (`FORK_ROBINHOOD=1 forge test --mc Fork`).
- The question hash the contract computes was checked against the live API: `POST /requests/quote` returns the same
  `questionHash` (also with double, leading and trailing spaces, symbols and mixed-case addresses in the text).
- `POST /requests/import` accepts the repo; `POST /requests/check` on the launch body returns no blockers.
- Frontend done (`frontend/`): demo mode until an address is set. Passes `pnpm lint` and `pnpm build`.

- Launch wallet created: `0x63BCf2d1483c7628d7D53704ff9c8199Dc28d907` (owner and fee recipient). Key and phrase in
  `~/.conditionals/wallet.txt` and `deployer.env` (chmod 600, never committed).
- Rehearsed on an anvil fork of Robinhood Chain: `launch/buy-imd.sh` bought exactly 0.5 IMD for ~0.0010 ETH, then
  approve and the launch payment succeeded; total ~0.00101 ETH. The site was tested in live mode against a fork
  deployment with a scripted wallet: connect, approve, stake, create, ask the oracle, void and claim all work.

- **LIVE: IMD launch 2278.** Conditionals at `0xc8cc656b71dd77ae1e29b0bc7890edd110e73255` on Robinhood Chain (deploy
  tx `0x7baf02fbc322ef9c583b8d50008b0a19fcc0e405ec200e484130a36cdf60da40`). Job `e854ea48-ee65-40eb-b029-f441e6b3b1a2`.
  Owner and fee recipient: `0x63BCf2d1483c7628d7D53704ff9c8199Dc28d907`. Verified onchain: IMD, Intake, signer, 0.5 IMD
  price, panel 5, quorum 4, action `oracle.request@oracle-1`, fees 300/200/100 bps.
- Audit: the first audit found a high bug (world B always settled NO; the outcome was never asked); the swarm fixed it
  and four lows, then the panel found a medium (dust counter-stake forcing a 3% fee); fixed by capping the fee at the
  losing pool. Final judge: no findings. Delivered commit `f6d3551` merged; 106 tests pass. Manifest archived as
  `launch/2278-manifest.json` (a root `launch.json` would block another launch kind).
- Launch paid with 0.5 IMD (tx `0x7da2c11732bb2d3d59cfcced9bafc99ab096ac4c378c8094df01887f3ec276eb`); the wallet has
  ~0.00198 ETH left.
- Site: https://conditionals-bay.vercel.app, live mode against the deployed address (Vercel project
  `ugwujageorges-projects/conditionals`, root `frontend/`, GitHub connected so pushes to `main` redeploy). Vercel CLI for
  George: `vercel --global-config ~/.vercel-george --scope ugwujageorges-projects`. `conditionals.vercel.app` is someone
  else's site. Tested against a fork with the deployed bytecode: connect, create, stake.

**(Superseded: see the 2026-10-29 session at the top.)** Earlier next steps: X account, submission, custom domain, first market.
custom domain (conditionals.markets or conditionals.xyz were available), and a first real market.**

## Launch steps (one paid launch, 0.5 IMD)

1. Wallet key in `~/.conditionals/deployer.env` as `PRIVATE_KEY=0x...` (never committed). It needs 0.5 IMD and a little
   ETH on Robinhood Chain. The payer is the deployer IMD records (`paidBy`).
2. `launch/pay.sh build <owner> <feeRecipient>`: writes `launch/launch.json` pinned to HEAD.
3. `launch/pay.sh approve`, then `launch/pay.sh launch` (it runs the free check first and pays only on no blockers).
4. Follow `GET https://api.imd.fun/intake/4663/<txHash>`, then the job and `GET /launches/:id` for the address.
5. Merge the swarm's delivered commit, set `DEPLOYED` in `frontend/src/lib/config.ts` (or
   `NEXT_PUBLIC_CONDITIONALS_ADDRESS` on Vercel), run `pnpm abi` if the ABI changed, redeploy.
6. Submit at imdradar.site/hackathon with the project X handle, a description and the contract address.

## Lessons carried over from GAMMA

- Any open medium or high finding parks the launch and the 0.5 IMD is lost; a parked launch cannot be retried.
- Steps must be `audit-imported-code`, `adapt-contract-project`, `adversarial-review` with `shape: "chain"`.
- Always `POST /requests/check` before paying. IMD may register a payment hours late; it is fine onchain.
- Commits: conventional format, no co-author or AI mention.
