// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

// @dev: Compiled with Solidity 0.8.24 and viaIR enabled

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
using SafeERC20 for IERC20;

// ─── Interfaces ──────────────────────────────────────────────────────────────

interface IFactory {
    function getPairAddress(address, address) external view returns (address);
    function feeTo() external view returns (address);
    function createPair(address tokenA, address tokenB) external returns (address pair);
}

interface IPair {
    function getReserves() external view returns (uint112, uint112, uint32);
    function swap(uint256, uint256, address) external;
    function mint(address) external returns (uint256);
    function burn(address) external returns (uint256, uint256);
    function token0() external view returns (address);
}

interface IEligibleTokenRegistry {
    function isEligible(address token) external view returns (bool);
}

interface ITimbPrize {
    function nudgeScroll() external;
    function isSettlementWindow() external view returns (bool);
    function currentRound() external view returns (uint256);
    function currentSegment() external view returns (uint256);
}

interface IWETH {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

// ─── Contract ────────────────────────────────────────────────────────────────

/**
 * @title TimbSwapRouter
 * @notice Routes swaps and liquidity through TimbSwap AMM pairs.
 */
contract TimbSwapRouter is Ownable, ReentrancyGuard {

    // ─── Immutables ──────────────────────────────────────────────────────────

    address public immutable factory;

    // ─── State ───────────────────────────────────────────────────────────────

    address public treasury;
    address public eligibleRegistry;
    address public timbPrize;
    bool    public paused;
    address public weth;

    // ─── Prize-meter tuning (see dev-docs/PRIZE_GAME_BALANCE_SPEC.md) ──────────────

    /// @notice #2 — meter units an eligible swap is worth. A swap moves the
    ///         scroll by this many nudges (each a separate nudgeScroll call),
    ///         so the meter race routes through the AMM and feeds the fee/burn
    ///         loop. Owner-set, 1..MAX_SWAP_NUDGE_WEIGHT.
    uint256 public swapNudgeWeight = 3;

    /// @notice #1 — max gas-only (advanceScroll) nudges one address may make
    ///         per segment. Paid swap-nudges are NOT capped (they cost fees
    ///         per wallet, so sybil doesn't help). 0 = free path disabled.
    uint256 public freeNudgeCapPerSeg = 10;

    /// @notice Free-nudge usage, keyed by keccak256(timbPrize, round, segment,
    ///         user) so the cap auto-resets every segment with no cleanup, AND is
    ///         namespaced by the prize instance. Each game generation deploys a
    ///         fresh TimbPrize and repoints this router at it (setTimbPrize), so
    ///         a new generation's round 1 / segment 2 gets a distinct key from a
    ///         prior generation's — otherwise the reused router would inherit
    ///         stale per-(round,segment) usage across a migration and wrongly
    ///         report "free nudges used" on the fresh game (gen-3 hit exactly
    ///         this — see dev-docs/GEN3_MIGRATION.md).
    mapping(bytes32 => uint256) public freeNudgesUsed;

    // ─── Constants ───────────────────────────────────────────────────────────

    uint256 public constant PROTOCOL_FEE_BPS = 5;
    uint256 public constant BPS_DENOMINATOR  = 10_000;

    /// @notice Gas-bounded cap for batched user nudges per transaction.
    uint256 public constant MAX_BATCH_NUDGE = 20;

    /// @notice Sanity ceiling for swapNudgeWeight.
    uint256 public constant MAX_SWAP_NUDGE_WEIGHT = 10;

    /// @notice Max hops in a path-based swap (path.length <= MAX_HOPS + 1).
    ///         3 bounds gas and covers every realistic route (X->WETH->Y is 2).
    uint256 public constant MAX_HOPS = 3;

    // ─── Events ──────────────────────────────────────────────────────────────

    event SwapExecuted(address sender, address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut, address to);
    event LiquidityAdded(address indexed pair, address indexed provider, uint256 amountA, uint256 amountB, uint256 liquidity);
    event LiquidityRemoved(address indexed pair, address indexed provider, uint256 amountA, uint256 amountB, uint256 liquidity);
    event ProtocolFeeSent(address indexed treasury, address indexed token, uint256 amount);
    event ScrollNudged(address indexed swapper, address indexed tokenIn);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event EligibleRegistrySet(address indexed registry);
    event TimbPrizeSet(address indexed timbPrize);
    event Paused(address indexed by);
    event Unpaused(address indexed by);
    event SwapNudgeWeightSet(uint256 weight);
    event FreeNudgeCapSet(uint256 capPerSegment);

    // ─── Errors ──────────────────────────────────────────────────────────────

    error ZeroAddress();
    error Expired(uint256 deadline);
    error RouterPaused();
    error PairNotFound(address tokenA, address tokenB);
    error InsufficientOutputAmount(uint256 amountOut, uint256 amountOutMin);
    error InsufficientAAmount(uint256 amountA, uint256 amountAMin);
    error InsufficientBAmount(uint256 amountB, uint256 amountBMin);
    error ExcessiveInputAmount();
    error ZeroAmount();
    error WethNotSet();
    error RefundFailed();
    error InsufficientLiquidity();
    error InsufficientETHSent(uint256 provided, uint256 required);
    error ETHTransferFailed();
    error InvalidNudgeCount(uint256 count, uint256 max);
    error PrizeNotSet();
    error FreeNudgeCapReached(uint256 round, uint256 segment);
    error InvalidPath();

    // ─── Modifiers ───────────────────────────────────────────────────────────

    modifier ensure(uint256 deadline) {
        if (block.timestamp > deadline) revert Expired(deadline);
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert RouterPaused();
        _;
    }

    // ─── Constructor ─────────────────────────────────────────────────────────

    constructor(
        address _factory,
        address _treasury,
        address _eligibleRegistry,
        address _timbPrize
    ) Ownable(msg.sender) {
        if (_factory  == address(0)) revert ZeroAddress();
        if (_treasury == address(0)) revert ZeroAddress();
        factory          = _factory;
        treasury         = _treasury;
        eligibleRegistry = _eligibleRegistry;
        timbPrize        = _timbPrize;
    }

    // ─── Owner Config ────────────────────────────────────────────────────────

    function setTreasury(address _treasury) external onlyOwner {
        if (_treasury == address(0)) revert ZeroAddress();
        emit TreasuryUpdated(treasury, _treasury);
        treasury = _treasury;
    }

    function setEligibleRegistry(address _r) external onlyOwner {
        eligibleRegistry = _r;
        emit EligibleRegistrySet(_r);
    }

    function setTimbPrize(address _p) external onlyOwner {
        timbPrize = _p;
        emit TimbPrizeSet(_p);
    }

    function pause()   external onlyOwner { paused = true;  emit Paused(msg.sender); }
    function unpause() external onlyOwner { paused = false; emit Unpaused(msg.sender); }

    function setWeth(address _weth) external onlyOwner {
        if (_weth == address(0)) revert ZeroAddress();
        weth = _weth;
    }

    // ─── Internal: Pair Helpers ───────────────────────────────────────────────

    function _getPair(address tokenA, address tokenB)
        internal view returns (address pair)
    {
        pair = IFactory(factory).getPairAddress(tokenA, tokenB);
        if (pair == address(0)) revert PairNotFound(tokenA, tokenB);
    }

    /// @dev Add-liquidity only: creates the pair on demand instead of reverting.
    /// Swaps/removeLiquidity keep using _getPair (nothing to trade or remove
    /// against a pair that doesn't exist yet).
    function _getOrCreatePair(address tokenA, address tokenB)
        internal returns (address pair)
    {
        pair = IFactory(factory).getPairAddress(tokenA, tokenB);
        if (pair == address(0)) {
            pair = IFactory(factory).createPair(tokenA, tokenB);
        }
    }

    function _getReserves(address pair, address tokenA)
        internal view returns (uint256 reserveA, uint256 reserveB)
    {
        (uint112 r0, uint112 r1,) = IPair(pair).getReserves();
        (reserveA, reserveB) = tokenA == IPair(pair).token0()
            ? (uint256(r0), uint256(r1))
            : (uint256(r1), uint256(r0));
    }

    // ─── Internal: Math ──────────────────────────────────────────────────────

    function _getAmountOut(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut
    ) internal pure returns (uint256) {
        if (amountIn == 0 || reserveIn == 0 || reserveOut == 0) revert ZeroAmount();
        uint256 fee = amountIn * 997;
        return (fee * reserveOut) / (reserveIn * 1_000 + fee);
    }

    function _getAmountIn(
        uint256 amountOut,
        uint256 reserveIn,
        uint256 reserveOut
    ) internal pure returns (uint256) {
        if (amountOut == 0 || reserveIn == 0 || reserveOut == 0) revert ZeroAmount();
        return (reserveIn * amountOut * 1_000) / ((reserveOut - amountOut) * 997) + 1;
    }

    function _quote(uint256 amountA, uint256 reserveA, uint256 reserveB)
        internal pure returns (uint256)
    {
        if (amountA == 0 || reserveA == 0 || reserveB == 0) revert ZeroAmount();
        return (amountA * reserveB) / reserveA;
    }

    // ─── Internal: Multi-hop quotes ───────────────────────────────────────────

    /// @dev Amounts along `path` for an exact input, front-to-back. Every
    ///      adjacent pair must exist (PairNotFound otherwise).
    function _getAmountsOut(uint256 amountIn, address[] calldata path)
        internal view returns (uint256[] memory amounts)
    {
        uint256 n = path.length;
        if (n < 2 || n > MAX_HOPS + 1) revert InvalidPath();
        amounts = new uint256[](n);
        amounts[0] = amountIn;
        for (uint256 i = 0; i < n - 1; i++) {
            if (path[i] == address(0) || path[i + 1] == address(0) || path[i] == path[i + 1]) {
                revert InvalidPath();
            }
            (uint256 reserveIn, uint256 reserveOut) =
                _getReserves(_getPair(path[i], path[i + 1]), path[i]);
            amounts[i + 1] = _getAmountOut(amounts[i], reserveIn, reserveOut);
        }
    }

    /// @dev Amounts along `path` for an exact output, filled back-to-front.
    function _getAmountsIn(uint256 amountOut, address[] calldata path)
        internal view returns (uint256[] memory amounts)
    {
        uint256 n = path.length;
        if (n < 2 || n > MAX_HOPS + 1) revert InvalidPath();
        amounts = new uint256[](n);
        amounts[n - 1] = amountOut;
        for (uint256 i = n - 1; i > 0; i--) {
            if (path[i] == address(0) || path[i - 1] == address(0) || path[i - 1] == path[i]) {
                revert InvalidPath();
            }
            (uint256 reserveIn, uint256 reserveOut) =
                _getReserves(_getPair(path[i - 1], path[i]), path[i - 1]);
            amounts[i - 1] = _getAmountIn(amounts[i], reserveIn, reserveOut);
        }
    }

    // ─── Internal: Protocol Fee ───────────────────────────────────────────────

    function _collectProtocolFee(address token, uint256 amountIn) internal {
        uint256 fee = (amountIn * PROTOCOL_FEE_BPS) / BPS_DENOMINATOR;
        if (fee > 0 && treasury != address(0)) {
            IERC20(token).safeTransferFrom(msg.sender, treasury, fee);
            emit ProtocolFeeSent(treasury, token, fee);
        }
    }

    // ─── Internal: Prize Nudge ────────────────────────────────────────────────

    function _maybeNudge(address tokenIn, bool influencePrize) internal {
        if (!influencePrize)                return;
        if (timbPrize == address(0))        return;
        if (eligibleRegistry == address(0)) return;
        try IEligibleTokenRegistry(eligibleRegistry).isEligible(tokenIn)
            returns (bool ok) { if (!ok) return; } catch { return; }
        try ITimbPrize(timbPrize).isSettlementWindow()
            returns (bool win) { if (win) return; } catch { return; }
        // #2 — an eligible swap is worth swapNudgeWeight meter units. Each is
        // a separate nudgeScroll() call; if the settlement window opens mid-loop
        // the call reverts and we stop cleanly. Swap-nudges are NOT counted
        // against the free-nudge cap — they're paid, hence self-limiting.
        uint256 w = swapNudgeWeight;
        uint256 done;
        for (uint256 i = 0; i < w; i++) {
            try ITimbPrize(timbPrize).nudgeScroll() { done++; } catch { break; }
        }
        if (done > 0) emit ScrollNudged(msg.sender, tokenIn);
    }

    // ─── Internal: Swap Direction ─────────────────────────────────────────────

    function _swapOnPair(address pair, address tokenIn, uint256 amountOut, address to)
        internal
    {
        bool isToken0 = IPair(pair).token0() == tokenIn;
        (uint256 a0, uint256 a1) = isToken0
            ? (uint256(0), amountOut)
            : (amountOut, uint256(0));
        IPair(pair).swap(a0, a1, to);
    }

    // ─── Internal: Swap Execution ────────────────────────────────────────────

    function _executeSwap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        address to,
        bool influencePrize
    ) internal {
        address pair = _getPair(tokenIn, tokenOut);
        IERC20(tokenIn).safeTransferFrom(msg.sender, pair, amountIn);
        _collectProtocolFee(tokenIn, amountIn);
        _swapOnPair(pair, tokenIn, amountOut, to);
        _maybeNudge(tokenIn, influencePrize);
        emit SwapExecuted(msg.sender, tokenIn, tokenOut, amountIn, amountOut, to);
    }

    /// @dev Multi-hop execution. The pair derives its input from balance
    ///      delta and enforces K per leg, so each hop pays its output
    ///      straight into the next hop's pair; the last hop pays `to`.
    ///      Router fee + prize nudge are keyed on path[0], once — identical
    ///      economics to a single-hop swap of the same input.
    function _executeSwapPath(
        address[] calldata path,
        uint256[] memory amounts,
        address to,
        bool influencePrize
    ) internal {
        uint256 n = path.length;

        address firstPair = _getPair(path[0], path[1]);
        IERC20(path[0]).safeTransferFrom(msg.sender, firstPair, amounts[0]);
        _collectProtocolFee(path[0], amounts[0]);

        for (uint256 i = 0; i < n - 1; i++) {
            address pair = i == 0 ? firstPair : _getPair(path[i], path[i + 1]);
            address next = i < n - 2 ? _getPair(path[i + 1], path[i + 2]) : to;
            _swapOnPair(pair, path[i], amounts[i + 1], next);
        }

        _maybeNudge(path[0], influencePrize);
        emit SwapExecuted(msg.sender, path[0], path[n - 1], amounts[0], amounts[n - 1], to);
    }

    // ─── View: Quote Helpers ──────────────────────────────────────────────────

    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut)
        external pure returns (uint256)
    { return _getAmountOut(amountIn, reserveIn, reserveOut); }

    function getAmountIn(uint256 amountOut, uint256 reserveIn, uint256 reserveOut)
        external pure returns (uint256)
    { return _getAmountIn(amountOut, reserveIn, reserveOut); }

    function quote(uint256 amountA, uint256 reserveA, uint256 reserveB)
        external pure returns (uint256)
    { return _quote(amountA, reserveA, reserveB); }

    function getReserves(address tokenA, address tokenB)
        external view returns (uint256 reserveA, uint256 reserveB)
    {
        address pair = IFactory(factory).getPairAddress(tokenA, tokenB);
        if (pair == address(0)) return (0, 0);
        return _getReserves(pair, tokenA);
    }

    /// @notice Amounts along a multi-hop path for an exact input — the
    ///         frontend quotes routes (and sizes amountOutMin) with this.
    function getAmountsOutPath(uint256 amountIn, address[] calldata path)
        external view returns (uint256[] memory amounts)
    { return _getAmountsOut(amountIn, path); }

    /// @notice Amounts along a multi-hop path for an exact output.
    function getAmountsInPath(uint256 amountOut, address[] calldata path)
        external view returns (uint256[] memory amounts)
    { return _getAmountsIn(amountOut, path); }

    // ─── Swap: Exact In ───────────────────────────────────────────────────────

    /**
     * @notice Swap an exact amount of tokenIn for as much tokenOut as possible.
     */
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address tokenIn,
        address tokenOut,
        address to,
        uint256 deadline,
        bool    influencePrize
    )
        external
        nonReentrant
        whenNotPaused
        ensure(deadline)
        returns (uint256 amountOut)
    {
        if (amountIn == 0)    revert ZeroAmount();
        if (to == address(0)) revert ZeroAddress();

        (uint256 reserveIn, uint256 reserveOut) = _getReserves(_getPair(tokenIn, tokenOut), tokenIn);
        amountOut = _getAmountOut(amountIn, reserveIn, reserveOut);

        if (amountOut < amountOutMin)
            revert InsufficientOutputAmount(amountOut, amountOutMin);

        _executeSwap(tokenIn, tokenOut, amountIn, amountOut, to, influencePrize);
    }

    // ─── Swap: Exact Out ──────────────────────────────────────────────────────

    /**
     * @notice Swap as little tokenIn as possible for an exact tokenOut amount.
     */
    function swapTokensForExactTokens(
        uint256 amountOut,
        uint256 amountInMax,
        address tokenIn,
        address tokenOut,
        address to,
        uint256 deadline,
        bool    influencePrize
    )
        external
        nonReentrant
        whenNotPaused
        ensure(deadline)
        returns (uint256 amountIn)
    {
        if (amountOut == 0)   revert ZeroAmount();
        if (to == address(0)) revert ZeroAddress();

        (uint256 reserveIn, uint256 reserveOut) = _getReserves(_getPair(tokenIn, tokenOut), tokenIn);
        amountIn = _getAmountIn(amountOut, reserveIn, reserveOut);

        if (amountIn > amountInMax) revert ExcessiveInputAmount();

        _executeSwap(tokenIn, tokenOut, amountIn, amountOut, to, influencePrize);
    }

    // ─── Swap: Multi-hop (path) ──────────────────────────────────────────────

    /**
     * @notice Swap an exact amount of path[0] along `path` (e.g.
     *         [USDT, WETH, TIMBS]) for as much path[last] as possible —
     *         for pairs with no direct pool. Every adjacent pair in the
     *         path must exist. The protocol fee and prize-nudge eligibility
     *         are keyed on path[0], once, exactly like a single-hop swap.
     */
    function swapExactTokensForTokensPath(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline,
        bool    influencePrize
    )
        external
        nonReentrant
        whenNotPaused
        ensure(deadline)
        returns (uint256 amountOut)
    {
        if (amountIn == 0)    revert ZeroAmount();
        if (to == address(0)) revert ZeroAddress();

        uint256[] memory amounts = _getAmountsOut(amountIn, path);
        amountOut = amounts[amounts.length - 1];
        if (amountOut < amountOutMin)
            revert InsufficientOutputAmount(amountOut, amountOutMin);

        _executeSwapPath(path, amounts, to, influencePrize);
    }

    /**
     * @notice Swap as little path[0] as possible along `path` for an exact
     *         amount of path[last].
     */
    function swapTokensForExactTokensPath(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to,
        uint256 deadline,
        bool    influencePrize
    )
        external
        nonReentrant
        whenNotPaused
        ensure(deadline)
        returns (uint256 amountIn)
    {
        if (amountOut == 0)   revert ZeroAmount();
        if (to == address(0)) revert ZeroAddress();

        uint256[] memory amounts = _getAmountsIn(amountOut, path);
        amountIn = amounts[0];
        if (amountIn > amountInMax) revert ExcessiveInputAmount();

        _executeSwapPath(path, amounts, to, influencePrize);
    }

    // ─── Swap: Native ETH ─────────────────────────────────────────────────────

    /**
     * @notice Swap an exact amount of native ETH for as much tokenOut as possible.
     * @dev ETH is wrapped to WETH and traded through the WETH/tokenOut pair.
     *      msg.value must cover amountIn plus the protocol fee (paid to the
     *      treasury as WETH, mirroring token-in swaps); excess ETH is refunded.
     */
    function swapExactETHForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address tokenOut,
        address to,
        uint256 deadline,
        bool    influencePrize
    )
        external
        payable
        nonReentrant
        whenNotPaused
        ensure(deadline)
        returns (uint256 amountOut)
    {
        if (weth == address(0)) revert WethNotSet();
        if (amountIn == 0)      revert ZeroAmount();
        if (to == address(0))   revert ZeroAddress();

        // Fee mirrors _collectProtocolFee: charged on top of amountIn, skipped
        // entirely when no treasury is configured.
        uint256 fee = treasury != address(0)
            ? (amountIn * PROTOCOL_FEE_BPS) / BPS_DENOMINATOR
            : 0;
        if (msg.value < amountIn + fee) {
            revert InsufficientETHSent(msg.value, amountIn + fee);
        }

        address pair = _getPair(weth, tokenOut);
        (uint256 reserveIn, uint256 reserveOut) = _getReserves(pair, weth);
        amountOut = _getAmountOut(amountIn, reserveIn, reserveOut);
        if (amountOut < amountOutMin) {
            revert InsufficientOutputAmount(amountOut, amountOutMin);
        }

        // Wrap once: swap amount to the pair, protocol fee (as WETH) to treasury.
        IWETH(weth).deposit{value: amountIn + fee}();
        IWETH(weth).transfer(pair, amountIn);
        if (fee > 0) {
            IWETH(weth).transfer(treasury, fee);
            emit ProtocolFeeSent(treasury, weth, fee);
        }

        _swapOnPair(pair, weth, amountOut, to);
        _maybeNudge(weth, influencePrize);
        _refundExcessETH(amountIn + fee);
        emit SwapExecuted(msg.sender, weth, tokenOut, amountIn, amountOut, to);
    }

    /**
     * @notice Swap an exact amount of tokenIn for as much native ETH as possible.
     * @dev Trades through the tokenIn/WETH pair; the router receives the WETH,
     *      unwraps it, and forwards native ETH to `to`.
     */
    function swapExactTokensForETH(
        uint256 amountIn,
        uint256 amountOutMin,
        address tokenIn,
        address to,
        uint256 deadline,
        bool    influencePrize
    )
        external
        nonReentrant
        whenNotPaused
        ensure(deadline)
        returns (uint256 amountOut)
    {
        if (weth == address(0)) revert WethNotSet();
        if (amountIn == 0)      revert ZeroAmount();
        if (to == address(0))   revert ZeroAddress();

        address pair = _getPair(tokenIn, weth);
        (uint256 reserveIn, uint256 reserveOut) = _getReserves(pair, tokenIn);
        amountOut = _getAmountOut(amountIn, reserveIn, reserveOut);
        if (amountOut < amountOutMin) {
            revert InsufficientOutputAmount(amountOut, amountOutMin);
        }

        IERC20(tokenIn).safeTransferFrom(msg.sender, pair, amountIn);
        _collectProtocolFee(tokenIn, amountIn);

        // Receive the WETH here, unwrap, and forward native ETH to the recipient.
        _swapOnPair(pair, tokenIn, amountOut, address(this));
        IWETH(weth).withdraw(amountOut);
        (bool ok,) = payable(to).call{value: amountOut}("");
        if (!ok) revert ETHTransferFailed();

        _maybeNudge(tokenIn, influencePrize);
        emit SwapExecuted(msg.sender, tokenIn, weth, amountIn, amountOut, to);
    }

    // ─── User Nudge (Advance the prize scroll) ───────────────────────────────

    /**
     * @notice Nudge the prize scroll directly, without swapping. `count` = 1
     *         is a single nudge; higher counts are a batch — accepted as one
     *         transaction and applied one nudge at a time, in order, which
     *         keeps concurrent batch requests cleanly sequenced on-chain.
     * @dev The router is the address TimbPrize authorizes for nudgeScroll(),
     *      so no TimbPrize change is needed. Each iteration inherits
     *      TimbPrize's own guards (whenGameStarted, settlement-window block).
     *
     *      #1 — this free (gas-only) path is capped per address per segment so
     *      one wallet can't dominate the meter for free. The request is
     *      CLAMPED to the remaining allowance rather than reverted, so a batch
     *      that overshoots still applies what it can; it only reverts when the
     *      caller has no allowance left this segment. Paid swap-nudges are not
     *      capped (see _maybeNudge).
     */
    function advanceScroll(uint256 count)
        external
        nonReentrant
        whenNotPaused
    {
        if (timbPrize == address(0)) revert PrizeNotSet();
        if (count == 0 || count > MAX_BATCH_NUDGE) {
            revert InvalidNudgeCount(count, MAX_BATCH_NUDGE);
        }

        uint256 round = ITimbPrize(timbPrize).currentRound();
        uint256 seg   = ITimbPrize(timbPrize).currentSegment();
        // Namespaced by the prize instance so a reused router doesn't carry
        // stale per-(round,segment) usage across a game-generation migration.
        bytes32 key   = keccak256(abi.encode(timbPrize, round, seg, msg.sender));
        uint256 used  = freeNudgesUsed[key];
        uint256 room  = freeNudgeCapPerSeg > used ? freeNudgeCapPerSeg - used : 0;
        uint256 n     = count < room ? count : room;
        if (n == 0) revert FreeNudgeCapReached(round, seg);

        freeNudgesUsed[key] = used + n;
        for (uint256 i = 0; i < n; i++) {
            ITimbPrize(timbPrize).nudgeScroll();
        }
        emit ScrollNudged(msg.sender, address(0)); // address(0) = direct nudge
    }

    /// @notice Remaining free (gas-only) nudges the caller may make this
    ///         segment. Frontend reads this to size the Advance batch so a
    ///         request never overshoots the cap. Resets each segment.
    function freeNudgesRemaining(address user) external view returns (uint256) {
        if (timbPrize == address(0)) return 0;
        uint256 round = ITimbPrize(timbPrize).currentRound();
        uint256 seg   = ITimbPrize(timbPrize).currentSegment();
        uint256 used  = freeNudgesUsed[keccak256(abi.encode(timbPrize, round, seg, user))];
        return freeNudgeCapPerSeg > used ? freeNudgeCapPerSeg - used : 0;
    }

    /// @notice Owner: set how many meter units an eligible swap is worth (#2).
    function setSwapNudgeWeight(uint256 weight) external onlyOwner {
        if (weight == 0 || weight > MAX_SWAP_NUDGE_WEIGHT) {
            revert InvalidNudgeCount(weight, MAX_SWAP_NUDGE_WEIGHT);
        }
        swapNudgeWeight = weight;
        emit SwapNudgeWeightSet(weight);
    }

    /// @notice Owner: set the per-address free-nudge cap per segment (#1).
    ///         0 disables the free path entirely (swaps still nudge).
    function setFreeNudgeCapPerSeg(uint256 capPerSegment) external onlyOwner {
        freeNudgeCapPerSeg = capPerSegment;
        emit FreeNudgeCapSet(capPerSegment);
    }

    // ─── Internal: Liquidity Helpers ─────────────────────────────────────────

    /// @dev Wrap native ETH into WETH and send to pair.
    function _wrapAndSend(address pair, uint256 amount) internal {
        if (weth == address(0)) revert WethNotSet();
        IWETH(weth).deposit{value: amount}();
        IWETH(weth).transfer(pair, amount);
    }

    /// @dev Compute optimal token amounts for adding liquidity.
    struct LiquidityParams {
        uint256 amountADesired;
        uint256 amountBDesired;
        uint256 amountAMin;
        uint256 amountBMin;
    }

    struct LiquidityState {
        address pair;
        uint256 amountA;
        uint256 amountB;
    }

    function _optimalAmounts(
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        uint256 reserveA,
        uint256 reserveB
    ) internal pure returns (uint256 amountA, uint256 amountB) {
        if (reserveA == 0 && reserveB == 0) {
            return (amountADesired, amountBDesired);
        }
        uint256 amountBOptimal = _quote(amountADesired, reserveA, reserveB);
        if (amountBOptimal <= amountBDesired) {
            if (amountBOptimal < amountBMin) revert InsufficientBAmount(amountBOptimal, amountBMin);
            return (amountADesired, amountBOptimal);
        }
        uint256 amountAOptimal = _quote(amountBDesired, reserveB, reserveA);
        if (amountAOptimal < amountAMin) revert InsufficientAAmount(amountAOptimal, amountAMin);
        return (amountAOptimal, amountBDesired);
    }

    function _optimalLiquidityAmounts(
        address pair,
        address tokenA,
        LiquidityParams memory p
    ) internal view returns (uint256 amountA, uint256 amountB) {
        (uint256 reserveA, uint256 reserveB) = _getReserves(pair, tokenA);
        return _optimalAmounts(
            p.amountADesired,
            p.amountBDesired,
            p.amountAMin,
            p.amountBMin,
            reserveA,
            reserveB
        );
    }

    // ─── Add Liquidity: Token/Token ───────────────────────────────────────────

    /**
     * @notice Add liquidity to a token/token pair.
     */
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    )
        external
        nonReentrant
        whenNotPaused
        ensure(deadline)
        returns (uint256 amountA, uint256 amountB, uint256 liquidity)
    {
        if (to == address(0)) revert ZeroAddress();

        LiquidityParams memory p = LiquidityParams({
            amountADesired: amountADesired,
            amountBDesired: amountBDesired,
            amountAMin: amountAMin,
            amountBMin: amountBMin
        });

        LiquidityState memory s = _prepareAddLiquidity(tokenA, tokenB, p);
        amountA = s.amountA;
        amountB = s.amountB;
        liquidity = _finalizeAddLiquidity(tokenA, tokenB, s, to);
    }

    /// @dev Internal logic for addLiquidity — isolated to reduce stack depth.
    function _prepareAddLiquidity(
        address tokenA,
        address tokenB,
        LiquidityParams memory p
    ) internal returns (LiquidityState memory s) {
        s.pair = _getOrCreatePair(tokenA, tokenB);
        (s.amountA, s.amountB) = _optimalLiquidityAmounts(s.pair, tokenA, p);
    }

    function _finalizeAddLiquidity(
        address tokenA,
        address tokenB,
        LiquidityState memory s,
        address to
    ) internal returns (uint256 liquidity) {
        IERC20(tokenA).safeTransferFrom(msg.sender, s.pair, s.amountA);
        IERC20(tokenB).safeTransferFrom(msg.sender, s.pair, s.amountB);
        liquidity = IPair(s.pair).mint(to);
        emit LiquidityAdded(s.pair, msg.sender, s.amountA, s.amountB, liquidity);
    }

    // ─── Add Liquidity: ETH/Token ─────────────────────────────────────────────

    /**
     * @notice Add liquidity to a WETH/token pair using native ETH.
     */
    function addLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    )
        external
        payable
        nonReentrant
        whenNotPaused
        ensure(deadline)
        returns (uint256 amountToken, uint256 amountETH, uint256 liquidity)
    {
        if (weth == address(0)) revert WethNotSet();
        if (to == address(0)) revert ZeroAddress();
        if (msg.value == 0) revert ZeroAmount();

        LiquidityState memory s = _prepareAddLiquidityETH(
            token,
            amountTokenDesired,
            msg.value,
            amountTokenMin,
            amountETHMin
        );

        amountToken = s.amountA;
        amountETH = s.amountB;
        liquidity = _finalizeAddLiquidityETH(token, s, to);
        _refundExcessETH(amountETH);
    }

    function _prepareAddLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256 ethDesired,
        uint256 amountTokenMin,
        uint256 amountETHMin
    ) internal returns (LiquidityState memory s) {
        s.pair = _getOrCreatePair(token, weth);
        (uint256 resToken, uint256 resETH) = _getReserves(s.pair, token);
        (s.amountA, s.amountB) = _optimalAmounts(
            amountTokenDesired,
            ethDesired,
            amountTokenMin,
            amountETHMin,
            resToken,
            resETH
        );
    }

    function _finalizeAddLiquidityETH(
        address token,
        LiquidityState memory s,
        address to
    ) internal returns (uint256 liquidity) {
        IERC20(token).safeTransferFrom(msg.sender, s.pair, s.amountA);
        _wrapAndSend(s.pair, s.amountB);
        liquidity = IPair(s.pair).mint(to);
        emit LiquidityAdded(s.pair, msg.sender, s.amountA, s.amountB, liquidity);
    }

    function _refundExcessETH(uint256 amountETH) internal {
        if (msg.value > amountETH) {
            (bool ok,) = payable(msg.sender).call{value: msg.value - amountETH}("");
            if (!ok) revert RefundFailed();
        }
    }

    // ─── Remove Liquidity: Token/Token ───────────────────────────────────────

    /// @dev Burns LP and returns sorted (amountA, amountB) relative to tokenA.
    function _burnAndSort(address pair, address tokenA, uint256 liquidity, address to)
        internal
        returns (uint256 amountA, uint256 amountB)
    {
        IERC20(pair).safeTransferFrom(msg.sender, pair, liquidity);
        (uint256 a0, uint256 a1) = IPair(pair).burn(to);
        (amountA, amountB) = (tokenA == IPair(pair).token0()) ? (a0, a1) : (a1, a0);
    }

    /**
     * @notice Remove liquidity from a token/token pair.
     */
    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    )
        external
        nonReentrant
        ensure(deadline)
        returns (uint256 amountA, uint256 amountB)
    {
        if (to == address(0)) revert ZeroAddress();
        address pair = _getPair(tokenA, tokenB);
        (amountA, amountB) = _burnAndSort(pair, tokenA, liquidity, to);
        if (amountA < amountAMin) revert InsufficientAAmount(amountA, amountAMin);
        if (amountB < amountBMin) revert InsufficientBAmount(amountB, amountBMin);
        emit LiquidityRemoved(pair, msg.sender, amountA, amountB, liquidity);
    }

    // ─── Remove Liquidity: ETH/Token ─────────────────────────────────────────

    /**
     * @notice Remove liquidity from a WETH/token pair, receiving native ETH.
     */
    function removeLiquidityETH(
        address token,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    )
        external
        nonReentrant
        ensure(deadline)
        returns (uint256 amountToken, uint256 amountETH)
    {
        if (weth == address(0)) revert WethNotSet();
        if (to == address(0))   revert ZeroAddress();
        return _doRemoveLiquidityETH(token, liquidity, amountTokenMin, amountETHMin, to);
    }

    /// @dev Internal logic for removeLiquidityETH — isolated to reduce stack depth.
    function _doRemoveLiquidityETH(
        address token,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to
    ) internal returns (uint256 amountToken, uint256 amountETH) {
        address pair = _getPair(token, weth);

        // Burn LP; receive both tokens here so we can unwrap WETH
        (amountToken, amountETH) = _burnAndSort(pair, token, liquidity, address(this));

        if (amountToken < amountTokenMin) revert InsufficientAAmount(amountToken, amountTokenMin);
        if (amountETH   < amountETHMin)   revert InsufficientBAmount(amountETH,   amountETHMin);

        IERC20(token).safeTransfer(to, amountToken);
        _unwrapAndSendETH(to, amountETH);

        emit LiquidityRemoved(pair, msg.sender, amountToken, amountETH, liquidity);
    }

    /// @dev Unwraps WETH and forwards native ETH to recipient.
    function _unwrapAndSendETH(address to, uint256 amount) internal {
        IWETH(weth).withdraw(amount);
        (bool ok,) = payable(to).call{value: amount}("");
        if (!ok) revert RefundFailed();
    }

    receive() external payable {}
}
