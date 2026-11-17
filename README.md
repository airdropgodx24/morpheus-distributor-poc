# Morpheus Phase 2 — fork PoC

`test/DonationYieldInflation.t.sol` — proves the DistributorV2 reward-share
inflation via direct yield-token (aWBTC) donation, Ethereum mainnet fork
pinned at block 26,433,720.

Run from this directory:

    forge test --match-contract DonationYieldInflation -vvv

Expected: PASS, with the quantified control-vs-attack logs in poc-output.txt.
Notes: the attacker is an unprivileged EOA that buys WBTC on Uniswap V3 with
dealt ETH (this forge build lacks the token-deal cheatcode). The three
ChainLink feeds with a 3600s staleness delay are re-mocked with their own
fork-block round data and a fresh updatedAt to simulate the hourly heartbeats
that occur in real time during the 1-day distribution window; prices are the
real fork-block values and the mechanism under test is untouched.
