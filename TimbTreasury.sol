// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";


// ─── Interfaces ──────────────────────────────────────────────────────────

using SafeERC20 for IERC20;

    interface ITimbsToken is IERC20 {
    function burn(uint256 amount) external;
}

    interface IWETH {
        function deposit() external payable;
        function withdraw(uint256 amount) external;
    }

    interface ITimbStaking {
        function notifyRewardAmount(uint256 amount, uint256 duration) external;
    }

    interface ITimbSwapPair {
        function getReserves() external view returns (uint112, uint112, uint32);
        function swap(uint256 amount0Out, uint256 amount1Out, address to) external;
        function token0() external view returns (address);
    }

    interface IPrizeEscrow {
        function deposit() external payable;
        function timbPrize() external view returns (address);
    }

    interface ITimbPrizePot {
        function addToPot() external payable;
        function prizeEscrow() external view returns (address);
    }

    interface ITimbSwapRouter {
        function addLiquidity(
            address tokenA,
            address tokenB,
            uint256 amountADesired,
            uint256 amountBDesired,
            uint256 amountAMin,
            uint256 amountBMin,
            address to,
            uint256 deadline
        ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity);

        function addLiquidityETH(
            address token,
            uint256 amountTokenDesired,
            uint256 amountTokenMin,
            uint256 amountETHMin,
            address to,
            uint256 deadline
        ) external payable returns (uint256 amountToken, uint256 amountETH, uint256 liquidity);
    }

/**
 * @title TimbTreasury
 * @notice Protocol fee routing, buyback execution, and revenue distribution.
 *
 * Revenue inflows:
 *   - 0.05% protocol swap fee (from TimbSwapRouter)
 *   - Round settlement cut from TimbPrize (owner-set %)
 *   - Expired unclaimed winnings dividend (owner-toggle)
 *   - Direct owner deposits (operations, grants)
 *
 * Revenue outflows:
 *   - Buyback: uses ETH to purchase TIMBS from TIMBS/ETH pair, split 3 ways
 *       └── buybackBurnRatio%    of purchased TIMBS → burned
 *       └── buybackReserveRatio% → kept as standing reserve (stacks, never
 *                                  auto-distributed)
 *       └── remainder            → waterfall slice: stays in the treasury but
 *                                  emitted as timbsToWaterfall so the epoch
 *                                  keeper distributes it to farm / staking /
 *                                  boost. A buyback moves out only the burn.
 *   - Prize pot top-up → PrizeEscrow
 *   - Staking reward top-up → TimbStaking.notifyRewardAmount()
 *   - Protocol-owned liquidity → Router.addLiquidity[ETH] (LP held here)
 *   - Operations → owner wallet (manual)
 *
 * Security:
 *   - ReentrancyGuard on executeBuyback(), distributeToPot(), distributeToStaking().
 *   - Buyback slippage protection: minTimbsOut parameter.
 *   - Only owner executes buybacks and distributions.
 *   - TIMBS burn via TIMBSToken.burn() — irreversible.
 *   - SafeERC20 on all token operations.
 *   - ETH never held beyond operational needs — distributed promptly.
 *
 * Deployment:
 *   1. Deploy TimbTreasury(timbsToken, timbStaking, prizeEscrow, pair)
 *   2. router.setTreasury(address(this))
 *   3. timbStaking.setTreasury(address(this))
 *   4. prizeEscrow owner deposits routed here
 *   5. Verify on Sourcify
 */
contract TimbTreasury is Ownable2Step, ReentrancyGuard {

    // ─── State ───────────────────────────────────────────────────────────────

    /// @notice TIMBS token — purchased in buybacks, burned or distributed.
    ITimbsToken public immutable timbsToken;

    /// @notice TimbStaking — receives TIMBS distribution share of buyback.
    address public timbStaking;

    /// @notice PrizeEscrow — receives ETH pot top-ups.
    address public prizeEscrow;

    /// @notice TIMBS/ETH AMM pair — used for buyback execution.
    address public timbsEthPair;

    /// @notice TimbSwapRouter — used to deploy treasury-held tokens as
    ///         protocol-owned liquidity. LP tokens are minted back to the
    ///         treasury (`to = address(this)`). Re-wireable via `setRouter`.
    address public router;

    /// @notice WETH — the pair holds WETH, not native ETH. Buyback ETH is
    ///         wrapped here before being paid into the pair.
    address public weth;

    /// @notice % of purchased TIMBS burned on each buyback (0–100).
    ///         Deflationary sink. `burn + reserve` must stay ≤ 100; the
    ///         remainder is the waterfall slice (see `buybackReserveRatio`).
    uint256 public buybackBurnRatio;

    /// @notice % of purchased TIMBS kept back in the treasury as a standing
    ///         reserve on each buyback (0–100). Never auto-distributed — it
    ///         stacks sweep over sweep as a solvency buffer. `burn + reserve`
    ///         must stay ≤ 100.
    ///
    ///         The rest — `100 − burn − reserve` — is the **waterfall slice**:
    ///         it also stays in the treasury's TIMBS balance, but is emitted as
    ///         `timbsToWaterfall` so the epoch keeper can measure it as the
    ///         per-epoch budget (`z`) it distributes to farm / staking / boost.
    ///         Staking is funded through that waterfall, NOT a direct transfer
    ///         here — a buyback moves no TIMBS out except the burn.
    uint256 public buybackReserveRatio;

    /// @notice Default staking distribution period when topping up staking
    ///         via the manual `distributeToStaking` path.
    uint256 public stakingDistributionPeriod;

    /// @notice Authorised callers for receiveFees() (Router, TimbPrize).
    mapping(address => bool) public authorisedFeeSenders;

    /// @notice Total ETH received as protocol fees (lifetime).
    uint256 public totalFeesReceived;

    /// @notice Total TIMBS burned via buybacks (lifetime).
    uint256 public totalTimbsBurned;

    /// @notice Total TIMBS distributed to stakers via the manual
    ///         `distributeToStaking` path (lifetime).
    uint256 public totalTimbsDistributed;

    /// @notice Total TIMBS routed to the epoch waterfall via buybacks
    ///         (lifetime) — the retained slice the keeper measures as `z`.
    uint256 public totalTimbsToWaterfall;

    /// @notice Total TIMBS held back as standing reserve via buybacks
    ///         (lifetime). Stays in the treasury balance; stacks over time.
    uint256 public totalTimbsReserved;

    /// @notice Total ETH sent to prize pot (lifetime).
    uint256 public totalPotFunded;

    // ─── Operator role (M1) ────────────────────────────────────────────────────
    // The owner is meant to be a timelock+multisig (see dev-docs/GOVERNANCE_
    // HARDENING.md), so routine, small operational ETH spend would otherwise wait
    // out the full timelock delay. A separate `operator` may withdraw ETH up to a
    // rolling per-period cap — least privilege for day-to-day ops. Everything
    // dangerous (uncapped withdrawals, ERC20 sweeps, retargeting outflow
    // addresses) stays with the timelock owner. The cap defaults to 0, so the
    // operator can do nothing until the owner explicitly funds the allowance.

    /// @notice Rate-limited operational spender (address(0) = disabled).
    address public operator;
    /// @notice Max ETH the operator may withdraw per rolling window.
    uint256 public operatorEthCap;
    /// @notice Length of the operator's rolling spend window.
    uint256 public operatorPeriod = 1 days;
    /// @notice Start of the current window (lazily rolled forward).
    uint256 public operatorWindowStart;
    /// @notice ETH the operator has withdrawn in the current window.
    uint256 public operatorSpentInWindow;

    // ─── Events ──────────────────────────────────────────────────────────────

    event FeesReceived(address indexed from, uint256 amount);
    event BuybackExecuted(
        uint256 ethSpent,
        uint256 timbsBought,
        uint256 timbsBurned,
        uint256 timbsToWaterfall,
        uint256 timbsReserved
    );
    event PotFunded(uint256 amount);
    event RouterSet(address indexed router);
    event LiquidityProvided(
        address indexed tokenA,
        address indexed tokenB,
        uint256 amountA,
        uint256 amountB,
        uint256 liquidity
    );
    event StakingFunded(uint256 timbsAmount, uint256 duration);
    event BuybackBurnRatioSet(uint256 ratio);
    event BuybackReserveRatioSet(uint256 ratio);
    event StakingSet(address indexed staking);
    event PrizeEscrowSet(address indexed escrow);
    event PairSet(address indexed pair);
    event FeeSenderSet(address indexed sender, bool authorised);
    event OperationalWithdraw(address indexed to, uint256 amount);
    event OperatorSet(address indexed operator);
    event OperatorEthCapSet(uint256 cap, uint256 period);

    // ─── Errors ──────────────────────────────────────────────────────────────

    error ZeroAddress();
    error ZeroAmount();
    error InvalidRatio(uint256 ratio);
    error SlippageExceeded(uint256 received, uint256 minimum);
    error BuybackFailed();
    error InsufficientETH(uint256 requested, uint256 available);
    error NotAuthorised();
    error TransferFailed();
    error OperatorCapExceeded(uint256 requested, uint256 remaining);
    error EscrowMismatch(address timbPrize);

    // ─── Modifiers ─────────────────────────────────────────────────────────────

    /// @dev The timelock owner, or the rate-limited operator (M1).
    modifier onlyOwnerOrOperator() {
        if (msg.sender != owner() && msg.sender != operator) revert NotAuthorised();
        _;
    }

    // ─── Constructor ─────────────────────────────────────────────────────────

    /**
     * @param _timbsToken   TIMBS token address.
     * @param _timbStaking  TimbStaking contract address.
     * @param _prizeEscrow  PrizeEscrow contract address.
     * @param _timbsEthPair TIMBS/ETH pair address (set after pair deploy).
     * @param _weth         WETH address (pair reserves are WETH-denominated).
     */
    constructor(
        address _timbsToken,
        address _timbStaking,
        address _prizeEscrow,
        address _timbsEthPair,
        address _weth
    ) Ownable(msg.sender) {
        if (_timbsToken == address(0)) revert ZeroAddress();

        timbsToken              = ITimbsToken(_timbsToken);
        timbStaking             = _timbStaking;
        prizeEscrow             = _prizeEscrow;
        timbsEthPair            = _timbsEthPair;
        weth                    = _weth;
        buybackBurnRatio        = 5;  // 5% burned
        buybackReserveRatio     = 20; // 20% held as reserve; 75% → waterfall
        stakingDistributionPeriod = 30 days;

        authorisedFeeSenders[msg.sender] = true;
    }

    // ─── Fee Reception ────────────────────────────────────────────────────────

    /**
     * @notice Receive protocol fees from Router or TimbPrize.
     * @dev Router sends 0.05% swap fees here.
     *      TimbPrize sends round settlement cut here.
     */
    function receiveFees() external payable {
        if (msg.value == 0) revert ZeroAmount();
        totalFeesReceived += msg.value;
        emit FeesReceived(msg.sender, msg.value);
    }

    // ─── Buyback Execution ────────────────────────────────────────────────────

    /**
     * @notice Execute a TIMBS buyback using ETH held in treasury.
     * @dev Buys TIMBS from TIMBS/ETH pair directly. Splits the purchase three
     *      ways — buybackBurnRatio% burned, buybackReserveRatio% kept as
     *      reserve, remainder retained as the waterfall slice for the epoch
     *      keeper. Only the burn leaves the treasury. Slippage protected via
     *      minTimbsOut.
     *
     * @param ethAmount    ETH to spend on buyback.
     * @param minTimbsOut  Minimum TIMBS to receive (slippage protection).
     */
    function executeBuyback(uint256 ethAmount, uint256 minTimbsOut)
        external
        nonReentrant
        onlyOwner
    {
        if (ethAmount == 0)                        revert ZeroAmount();
        if (ethAmount > address(this).balance)     revert InsufficientETH(ethAmount, address(this).balance);
        if (timbsEthPair == address(0))            revert ZeroAddress();

        // Get reserves to calculate amountOut
        (uint112 r0, uint112 r1,) = ITimbSwapPair(timbsEthPair).getReserves();
        address token0 = ITimbSwapPair(timbsEthPair).token0();

        // Determine which reserve is ETH and which is TIMBS
        // ETH side = address(0) represented as WETH — for testnet we handle
        // native ETH by sending directly to pair before swap
        uint256 reserveIn;
        uint256 reserveOut;
        bool timbsIsToken0 = token0 == address(timbsToken);

        if (timbsIsToken0) {
            // token0 = TIMBS, token1 = ETH/WETH
            reserveIn  = uint256(r1); // ETH reserve
            reserveOut = uint256(r0); // TIMBS reserve
        } else {
            // token0 = ETH/WETH, token1 = TIMBS
            reserveIn  = uint256(r0); // ETH reserve
            reserveOut = uint256(r1); // TIMBS reserve
        }

        // Calculate TIMBS out with 0.3% fee
        uint256 amountInWithFee = ethAmount * 997;
        uint256 timbsOut = (amountInWithFee * reserveOut) /
                           (reserveIn * 1_000 + amountInWithFee);

        if (timbsOut < minTimbsOut) {
            revert SlippageExceeded(timbsOut, minTimbsOut);
        }

        if (weth == address(0)) revert ZeroAddress();

        // The pair holds WETH, not native ETH (it has no receive()) — and its
        // swap() derives the input from its ERC20 balance delta. Wrap first,
        // then pay the WETH into the pair like any other swap input.
        IWETH(weth).deposit{value: ethAmount}();
        IERC20(weth).safeTransfer(timbsEthPair, ethAmount);

        // Measure what THIS swap bought (balance delta), never the treasury's
        // whole TIMBS balance — pre-existing holdings must not be swept into
        // the split or mask slippage.
        uint256 balBefore = timbsToken.balanceOf(address(this));

        if (timbsIsToken0) {
            ITimbSwapPair(timbsEthPair).swap(timbsOut, 0, address(this));
        } else {
            ITimbSwapPair(timbsEthPair).swap(0, timbsOut, address(this));
        }

        uint256 received = timbsToken.balanceOf(address(this)) - balBefore;
        if (received < minTimbsOut) revert SlippageExceeded(received, minTimbsOut);

        // Three-way split: burn / reserve / waterfall. Only the burn leaves
        // the treasury — `reserve` and `waterfall` both stay in this contract's
        // TIMBS balance. The split is pure accounting: `waterfall` is emitted so
        // the epoch keeper can measure it as the per-epoch budget it hands to
        // farm / staking / boost; `reserve` is the residual that stacks as a
        // solvency buffer. `waterfall = received − burn − reserve`, so the
        // event's (bought − burned − reserved) equals exactly the waterfall
        // slice the keeper distributes.
        uint256 toBurn      = (received * buybackBurnRatio) / 100;
        uint256 toReserve   = (received * buybackReserveRatio) / 100;
        uint256 toWaterfall = received - toBurn - toReserve;

        if (toBurn > 0) {
            timbsToken.burn(toBurn);
            totalTimbsBurned += toBurn;
        }

        totalTimbsToWaterfall += toWaterfall;
        totalTimbsReserved    += toReserve;

        emit BuybackExecuted(ethAmount, received, toBurn, toWaterfall, toReserve);
    }

    // ─── Distribution ─────────────────────────────────────────────────────────

    /**
     * @notice Send ETH from treasury to top up the prize pot.
     * @dev    Goes through TimbPrize.addToPot, which credits
     *         currentAccumulatedRewards before depositing into PrizeEscrow.
     *         Depositing into the escrow directly (the old path) left the ETH
     *         outside the counter settlement pays from, so it could never
     *         reach a winner (TS-006). The prize is the one the escrow pays
     *         for, and it must deposit into this treasury's escrow.
     * @param amount ETH amount to send.
     */
    function distributeToPot(uint256 amount)
        external
        nonReentrant
        onlyOwner
    {
        if (amount == 0)                     revert ZeroAmount();
        if (prizeEscrow == address(0))       revert ZeroAddress();
        if (amount > address(this).balance)  revert InsufficientETH(amount, address(this).balance);

        address prize = IPrizeEscrow(prizeEscrow).timbPrize();
        if (prize == address(0))                             revert ZeroAddress();
        if (ITimbPrizePot(prize).prizeEscrow() != prizeEscrow) revert EscrowMismatch(prize);

        ITimbPrizePot(prize).addToPot{value: amount}();
        totalPotFunded += amount;

        emit PotFunded(amount);
    }

    /**
     * @notice Top up TimbStaking rewards directly with TIMBS from treasury.
     * @dev Treasury must hold TIMBS (transferred from community allocation).
     *      Single funding path: TimbStaking.notifyRewardAmount pulls the TIMBS
     *      itself via transferFrom, so approve it and let it pull. The previous
     *      code ALSO pre-transferred the amount, so the call either reverted for
     *      lack of allowance (what the deployed Sepolia v4 does — the epoch
     *      keeper routes around it) or, had the allowance been granted, would
     *      have paid twice. Mirrors audit fix M5 on the mainnet lineage. The
     *      residual allowance is cleared afterwards, as in the addLiquidity
     *      paths below.
     * @param timbsAmount TIMBS amount to distribute.
     * @param duration    Distribution period in seconds.
     */
    function distributeToStaking(uint256 timbsAmount, uint256 duration)
        external
        nonReentrant
        onlyOwner
    {
        if (timbsAmount == 0)        revert ZeroAmount();
        if (duration == 0)           revert ZeroAmount();
        if (timbStaking == address(0)) revert ZeroAddress();

        uint256 bal = timbsToken.balanceOf(address(this));
        if (timbsAmount > bal) revert ZeroAmount();

        IERC20(address(timbsToken)).forceApprove(timbStaking, timbsAmount);
        ITimbStaking(timbStaking).notifyRewardAmount(timbsAmount, duration);
        IERC20(address(timbsToken)).forceApprove(timbStaking, 0);

        emit StakingFunded(timbsAmount, duration);
    }

    // ─── Protocol-owned liquidity ───────────────────────────────────────────────

    /**
     * @notice Deploy two treasury-held ERC20s as liquidity. LP tokens are
     *         minted back to the treasury — protocol-owned, not the owner's.
     * @dev Both tokens must already sit in this contract (e.g. TIMBS from the
     *      buyback reserve/waterfall + a stable transferred in). The router
     *      pulls only what's needed at the pool ratio; any un-deposited dust
     *      stays here. If the pair doesn't exist, the factory creates it.
     * @param tokenA          First token.
     * @param tokenB          Second token.
     * @param amountADesired  Max tokenA to deposit.
     * @param amountBDesired  Max tokenB to deposit.
     * @param amountAMin      Slippage floor on tokenA actually deposited.
     * @param amountBMin      Slippage floor on tokenB actually deposited.
     */
    function provideLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin
    ) external nonReentrant onlyOwner {
        if (router == address(0))                    revert ZeroAddress();
        if (tokenA == address(0) || tokenB == address(0)) revert ZeroAddress();
        if (amountADesired == 0 || amountBDesired == 0)   revert ZeroAmount();

        IERC20(tokenA).forceApprove(router, amountADesired);
        IERC20(tokenB).forceApprove(router, amountBDesired);

        (uint256 amountA, uint256 amountB, uint256 liquidity) =
            ITimbSwapRouter(router).addLiquidity(
                tokenA, tokenB,
                amountADesired, amountBDesired,
                amountAMin, amountBMin,
                address(this), block.timestamp
            );

        // Drop any residual allowance the router didn't consume.
        IERC20(tokenA).forceApprove(router, 0);
        IERC20(tokenB).forceApprove(router, 0);

        emit LiquidityProvided(tokenA, tokenB, amountA, amountB, liquidity);
    }

    /**
     * @notice Deploy treasury-held TIMBS (or any token) + treasury ETH as
     *         liquidity. LP tokens are minted back to the treasury.
     * @dev Uses native ETH held here (unwrap WETH fee revenue first via
     *      `unwrapWeth` if needed). Router refunds any excess ETH to the
     *      treasury. Pairs against WETH under the hood.
     * @param token               Token to pair with ETH.
     * @param amountTokenDesired  Max token to deposit.
     * @param ethAmount           ETH to deposit (≤ treasury balance).
     * @param amountTokenMin      Slippage floor on token deposited.
     * @param amountETHMin        Slippage floor on ETH deposited.
     */
    function provideLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256 ethAmount,
        uint256 amountTokenMin,
        uint256 amountETHMin
    ) external nonReentrant onlyOwner {
        if (router == address(0))            revert ZeroAddress();
        if (token == address(0))             revert ZeroAddress();
        if (amountTokenDesired == 0 || ethAmount == 0) revert ZeroAmount();
        if (ethAmount > address(this).balance) revert InsufficientETH(ethAmount, address(this).balance);

        IERC20(token).forceApprove(router, amountTokenDesired);

        (uint256 amountToken, uint256 amountETH, uint256 liquidity) =
            ITimbSwapRouter(router).addLiquidityETH{value: ethAmount}(
                token, amountTokenDesired, amountTokenMin, amountETHMin,
                address(this), block.timestamp
            );

        IERC20(token).forceApprove(router, 0);

        emit LiquidityProvided(token, weth, amountToken, amountETH, liquidity);
    }

    /**
     * @notice Withdraw any ERC20 held by the treasury (owner only).
     * @dev Protocol swap fees arrive as the swap's INPUT token (TIMBS, WETH,
     *      stables…), not ETH — this is the exit for everything the
     *      buyback/distribute flows don't cover, and the rescue that v1/v2
     *      lacked (v1 stranded its TIMBS fee balance permanently).
     */
    function withdrawToken(address token, address to, uint256 amount)
        external
        nonReentrant
        onlyOwner
    {
        if (token == address(0) || to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        IERC20(token).safeTransfer(to, amount);
        emit OperationalWithdraw(to, amount);
    }

    /**
     * @notice Unwrap WETH fee revenue into ETH — feeds executeBuyback /
     *         distributeToPot, which spend native ETH. Owner or operator: this
     *         only converts WETH the treasury already holds into ETH it already
     *         holds; it moves nothing out, so the operator may run it.
     */
    function unwrapWeth(uint256 amount) external nonReentrant onlyOwnerOrOperator {
        if (weth == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        IWETH(weth).withdraw(amount);
    }

    /**
     * @notice Withdraw ETH for operational expenses.
     * @dev The timelock owner is unbounded. The operator (M1) is rate-limited to
     *      `operatorEthCap` per rolling `operatorPeriod`, so a compromised
     *      operator key can never drain the treasury in one move — large or
     *      urgent spend goes through the timelock owner. Cap defaults to 0.
     */
    function withdrawOperational(address to, uint256 amount)
        external
        nonReentrant
        onlyOwnerOrOperator
    {
        if (to == address(0))              revert ZeroAddress();
        if (amount == 0)                   revert ZeroAmount();
        if (amount > address(this).balance) revert InsufficientETH(amount, address(this).balance);

        // Owner (timelock) is unbounded; the operator is capped per window.
        if (msg.sender != owner()) {
            // Lazily roll the window forward.
            if (block.timestamp >= operatorWindowStart + operatorPeriod) {
                operatorWindowStart   = block.timestamp;
                operatorSpentInWindow = 0;
            }
            uint256 remaining = operatorEthCap > operatorSpentInWindow
                ? operatorEthCap - operatorSpentInWindow
                : 0;
            if (amount > remaining) revert OperatorCapExceeded(amount, remaining);
            operatorSpentInWindow += amount;
        }

        (bool ok,) = payable(to).call{value: amount}("");
        if (!ok) revert TransferFailed();

        emit OperationalWithdraw(to, amount);
    }

    // ─── Owner: Config ────────────────────────────────────────────────────────

    /**
     * @notice Set buyback burn ratio (0–100). `burn + reserve` must stay ≤ 100;
     *         the remainder is the waterfall slice.
     */
    function setBuybackBurnRatio(uint256 _ratio) external onlyOwner {
        if (_ratio > 100 || _ratio + buybackReserveRatio > 100) revert InvalidRatio(_ratio);
        buybackBurnRatio = _ratio;
        emit BuybackBurnRatioSet(_ratio);
    }

    /**
     * @notice Set buyback reserve ratio (0–100) — the slice kept back as a
     *         standing buffer. `burn + reserve` must stay ≤ 100; the remainder
     *         is the waterfall slice the epoch keeper distributes.
     */
    function setBuybackReserveRatio(uint256 _ratio) external onlyOwner {
        if (_ratio > 100 || buybackBurnRatio + _ratio > 100) revert InvalidRatio(_ratio);
        buybackReserveRatio = _ratio;
        emit BuybackReserveRatioSet(_ratio);
    }

    function setTimbStaking(address _staking) external onlyOwner {
        if (_staking == address(0)) revert ZeroAddress();
        timbStaking = _staking;
        emit StakingSet(_staking);
    }

    function setPrizeEscrow(address _escrow) external onlyOwner {
        if (_escrow == address(0)) revert ZeroAddress();
        prizeEscrow = _escrow;
        emit PrizeEscrowSet(_escrow);
    }

    function setTimbsEthPair(address _pair) external onlyOwner {
        if (_pair == address(0)) revert ZeroAddress();
        timbsEthPair = _pair;
        emit PairSet(_pair);
    }

    function setRouter(address _router) external onlyOwner {
        if (_router == address(0)) revert ZeroAddress();
        router = _router;
        emit RouterSet(_router);
    }

    function setWeth(address _weth) external onlyOwner {
        if (_weth == address(0)) revert ZeroAddress();
        weth = _weth;
    }

    function setStakingDistributionPeriod(uint256 _period) external onlyOwner {
        if (_period == 0) revert ZeroAmount();
        stakingDistributionPeriod = _period;
    }

    /// @notice Set (or clear, with address(0)) the rate-limited operator (M1).
    function setOperator(address _operator) external onlyOwner {
        operator = _operator;
        emit OperatorSet(_operator);
    }

    /// @notice Set the operator's per-window ETH withdrawal cap and window length.
    ///         Setting the cap to 0 disables operator withdrawals entirely.
    function setOperatorEthCap(uint256 _cap, uint256 _period) external onlyOwner {
        if (_period == 0) revert ZeroAmount();
        operatorEthCap = _cap;
        operatorPeriod = _period;
        emit OperatorEthCapSet(_cap, _period);
    }

    function setFeeSender(address sender, bool authorised) external onlyOwner {
        if (sender == address(0)) revert ZeroAddress();
        authorisedFeeSenders[sender] = authorised;
        emit FeeSenderSet(sender, authorised);
    }

    // ─── View ─────────────────────────────────────────────────────────────────

    /**
     * @notice Returns treasury ETH balance.
     */
    function ethBalance() external view returns (uint256) {
        return address(this).balance;
    }

    /**
     * @notice Returns treasury TIMBS balance.
     */
    function timbsBalance() external view returns (uint256) {
        return timbsToken.balanceOf(address(this));
    }

    /**
     * @notice Returns lifetime treasury stats.
     */
    function getStats()
        external
        view
        returns (
            uint256 feesReceived,
            uint256 timbsBurned,
            uint256 timbsDistributed,
            uint256 potFunded
        )
    {
        return (
            totalFeesReceived,
            totalTimbsBurned,
            totalTimbsDistributed,
            totalPotFunded
        );
    }

    /// @dev Accept ETH from Router fee transfers and direct deposits.
    ///      WETH.withdraw refunds under a 2300-gas stipend — too little for
    ///      the accounting SSTORE+event, so that path returns early (it's an
    ///      internal conversion, not new revenue).
    receive() external payable {
        if (msg.sender == weth) return;
        if (msg.value > 0) {
            totalFeesReceived += msg.value;
            emit FeesReceived(msg.sender, msg.value);
        }
    }
}
