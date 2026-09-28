// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title TimbSwapPair
 * @notice Constant-product AMM pair (x * y = k) with LP tokens.
 *
 * Architecture:
 *   - Each pair is its own ERC20 (LP token), deployed by TimbSwapFactory.
 *   - In-pool fee: 0.30% per swap stays in reserves; of that, ~0.05% is taken
 *     as protocol fee via the lazy LP-dilution mint on mint/burn (Uniswap-v2
 *     `feeTo` pattern), leaving ~0.25% to LPs.
 *   - NOTE: the Router additionally charges a SEPARATE 0.05% protocol fee,
 *     transferred straight to the treasury on every router swap (see
 *     TimbSwapRouter._collectProtocolFee). So a swap ROUTED through the router
 *     costs ~0.35% total (0.30% in-pool + 0.05% router) and the protocol's
 *     total take is ~0.10%. A caller hitting swap() directly pays only the
 *     0.30% in-pool fee. If a true 0.30% total is intended, one of the two
 *     mechanisms must be removed — that is a tokenomics decision, not a bug.
 *   - Partner-pool / emissions-whitelist config on the factory is RESERVED —
 *     currently not read by the pair (no LP-fee rerouting is in effect).
 *
 * Security (defiSKILL):
 *   - ReentrancyGuard on mint(), burn(), swap().
 *   - DEX pair TOCTOU: _update() does NOT distinguish operation type by
 *     reserve/balance comparison. Operation type is determined by caller
 *     (Router) via explicit parameters — never inferred from balance delta.
 *   - Flash loan protection: swap() enforces the constant product invariant
 *     AFTER fee deduction — no free capital extraction.
 *   - Minimum liquidity lock (MINIMUM_LIQUIDITY = 1000) on first mint —
 *     prevents ERC4626-style inflation attack on LP share rounding.
 *   - Protocol fee collected lazily on mint/burn (Uniswap v2 pattern) —
 *     no per-swap storage write for the protocol fee.
 *   - swap() is PERMISSIONLESS (safe under the K invariant enforced after fee
 *     deduction). The router's extra 0.05% fee and the prize-nudge apply only
 *     to swaps routed through the router; a direct swap() caller bypasses them.
 *
 * TWAP:
 *   - price0CumulativeLast and price1CumulativeLast updated on every
 *     _update() call for future TWAP oracle integration.
 *
 * Deployment:
 *   - Deployed by TimbSwapFactory.createPair() via CREATE2.
 *   - Constructor sets token0, token1, factory — immutable after deploy.
 */
contract TimbSwapPair is ERC20, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ─── Constants ───────────────────────────────────────────────────────────

    /// @notice Minimum LP tokens locked forever on first mint.
    ///         Prevents share inflation attack via rounding on tiny deposits.
    uint256 public constant MINIMUM_LIQUIDITY = 1_000;

    /// @notice Protocol fee numerator (5 bps of the 30 bps total).
    uint256 private constant PROTOCOL_FEE_NUMERATOR = 5;

    /// @notice Fee denominator.
    uint256 private constant FEE_DENOMINATOR = 10_000;

    /// @notice Swap fee: 0.3% = 997/1000 of input kept by pool after fee.
    uint256 private constant SWAP_FEE_NUMERATOR = 997;
    uint256 private constant SWAP_FEE_DENOMINATOR = 1_000;

    // ─── Immutables ──────────────────────────────────────────────────────────

    /// @notice Factory that deployed this pair.
    address public immutable factory;

    /// @notice Lower-sorted token (token0 < token1).
    address public immutable token0;

    /// @notice Higher-sorted token.
    address public immutable token1;

    // ─── State ───────────────────────────────────────────────────────────────

    /// @notice Current reserve of token0.
    uint112 private reserve0;

    /// @notice Current reserve of token1.
    uint112 private reserve1;

    /// @notice Last block timestamp reserves were updated (for TWAP).
    uint32  private blockTimestampLast;

    /// @notice Cumulative price of token0 (token1 per token0), for TWAP.
    uint256 public price0CumulativeLast;

    /// @notice Cumulative price of token1 (token0 per token1), for TWAP.
    uint256 public price1CumulativeLast;

    /// @notice Last sqrt(k) snapshot for protocol fee calculation.
    uint256 public kLast;

    // ─── Events ──────────────────────────────────────────────────────────────

    event Mint(address indexed sender, uint256 amount0, uint256 amount1);
    event Burn(
        address indexed sender,
        uint256 amount0,
        uint256 amount1,
        address indexed to
    );
    event Swap(
        address indexed sender,
        uint256 amount0In,
        uint256 amount1In,
        uint256 amount0Out,
        uint256 amount1Out,
        address indexed to
    );
    event Sync(uint112 reserve0, uint112 reserve1);
    event ProtocolFeeCollected(address indexed feeTo, uint256 lpMinted);

    // ─── Errors ──────────────────────────────────────────────────────────────

    error InsufficientLiquidity();
    error InsufficientLiquidityMinted();
    error InsufficientLiquidityBurned();
    error InsufficientOutputAmount();
    error InsufficientInputAmount();
    error InvalidTo(address to);
    error KInvariantViolated();
    error Overflow();
    error ZeroAddress();

    // ─── Constructor ─────────────────────────────────────────────────────────

    /**
     * @param _token0   Lower-sorted token address.
     * @param _token1   Higher-sorted token address.
     * @dev factory is msg.sender (TimbSwapFactory).
     *      LP token name/symbol derived from token symbols.
     */
    constructor(address _token0, address _token1)
        ERC20("TimbSwap LP Token", "TIMBS-LP")
    {
        if (_token0 == address(0) || _token1 == address(0)) revert ZeroAddress();
        factory = msg.sender;
        token0  = _token0;
        token1  = _token1;
    }

    // ─── Reserve Getters ─────────────────────────────────────────────────────

    /**
     * @notice Returns current reserves and last update timestamp.
     */
    function getReserves()
        public
        view
        returns (
            uint112 _reserve0,
            uint112 _reserve1,
            uint32  _blockTimestampLast
        )
    {
        _reserve0          = reserve0;
        _reserve1          = reserve1;
        _blockTimestampLast = blockTimestampLast;
    }

    // ─── Internal: Reserve Update + TWAP ─────────────────────────────────────

    /**
     * @dev Updates reserves and TWAP accumulators.
     *      SECURITY: Does NOT infer operation type from balance/reserve delta.
     *      Caller (Router) is responsible for passing correct amounts.
     *      This prevents the DEX pair _transfer TOCTOU vulnerability.
     */
    function _update(
        uint256 balance0,
        uint256 balance1,
        uint112 _reserve0,
        uint112 _reserve1
    ) private {
        if (balance0 > type(uint112).max || balance1 > type(uint112).max) {
            revert Overflow();
        }

        uint32 blockTimestamp = uint32(block.timestamp % 2**32);
        uint32 timeElapsed;
        unchecked {
            timeElapsed = blockTimestamp - blockTimestampLast;
        }

        if (timeElapsed > 0 && _reserve0 != 0 && _reserve1 != 0) {
            // TWAP: accumulate price * time
            // UQ112x112 fixed-point: price = reserve1/reserve0 * 2^112
            unchecked {
                price0CumulativeLast +=
                    uint256((uint224(_reserve1) << 112) / _reserve0) * timeElapsed;
                price1CumulativeLast +=
                    uint256((uint224(_reserve0) << 112) / _reserve1) * timeElapsed;
            }
        }

        reserve0            = uint112(balance0);
        reserve1            = uint112(balance1);
        blockTimestampLast  = blockTimestamp;

        emit Sync(reserve0, reserve1);
    }

    // ─── Internal: Protocol Fee ───────────────────────────────────────────────

    /**
     * @dev Mints protocol fee LP tokens to feeTo if protocol fee is enabled.
     *      Called lazily on mint() and burn() — not on every swap.
     *      Uniswap v2 pattern: fee = growth in sqrt(k) since last snapshot.
     * @return feeOn True if feeTo is set and fee was collected.
     */
    function _mintProtocolFee(uint112 _reserve0, uint112 _reserve1)
        private
        returns (bool feeOn)
    {
        address feeTo = _getFeeTo();
        feeOn = feeTo != address(0);

        uint256 _kLast = kLast;
        if (feeOn) {
            if (_kLast != 0) {
                uint256 rootK     = Math.sqrt(uint256(_reserve0) * uint256(_reserve1));
                uint256 rootKLast = Math.sqrt(_kLast);
                if (rootK > rootKLast) {
                    uint256 numerator   = totalSupply() * (rootK - rootKLast);
                    // Protocol takes 1/6 of LP growth (= 0.05% of 0.3% total fee)
                    uint256 denominator = rootK * 5 + rootKLast;
                    uint256 liquidity   = numerator / denominator;
                    if (liquidity > 0) {
                        _mint(feeTo, liquidity);
                        emit ProtocolFeeCollected(feeTo, liquidity);
                    }
                }
            }
        } else if (_kLast != 0) {
            kLast = 0;
        }
    }

    /**
     * @dev Fetches feeTo from factory.
     */
    function _getFeeTo() private view returns (address) {
        // Inline interface call to avoid circular import
        (bool success, bytes memory data) = factory.staticcall(
            abi.encodeWithSignature("feeTo()")
        );
        if (!success || data.length < 32) return address(0);
        return abi.decode(data, (address));
    }

    // ─── Liquidity: Mint ──────────────────────────────────────────────────────

    /**
     * @notice Add liquidity and receive LP tokens.
     * @dev Caller (Router) must transfer token0 and token1 to this contract
     *      before calling mint(). LP tokens minted to `to`.
     *
     *      First deposit: MINIMUM_LIQUIDITY LP tokens burned to address(1)
     *      (dead address) permanently — prevents share inflation attack.
     *
     * @param to Address that receives LP tokens.
     * @return liquidity Amount of LP tokens minted.
     */
    function mint(address to)
        external
        nonReentrant
        returns (uint256 liquidity)
    {
        if (to == address(0)) revert ZeroAddress();
        if (to == token0 || to == token1) revert InvalidTo(to);

        (uint112 _reserve0, uint112 _reserve1,) = getReserves();

        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));

        uint256 amount0 = balance0 - _reserve0;
        uint256 amount1 = balance1 - _reserve1;

        bool feeOn = _mintProtocolFee(_reserve0, _reserve1);
        uint256 _totalSupply = totalSupply();

        if (_totalSupply == 0) {
            // First mint: geometric mean minus minimum liquidity
            liquidity = Math.sqrt(amount0 * amount1) - MINIMUM_LIQUIDITY;
            // Lock MINIMUM_LIQUIDITY forever — prevents inflation attack
            _mint(address(1), MINIMUM_LIQUIDITY);
        } else {
            // Subsequent mints: proportional to existing reserves
            liquidity = Math.min(
                (amount0 * _totalSupply) / _reserve0,
                (amount1 * _totalSupply) / _reserve1
            );
        }

        if (liquidity == 0) revert InsufficientLiquidityMinted();

        _mint(to, liquidity);

        _update(balance0, balance1, _reserve0, _reserve1);

        if (feeOn) kLast = uint256(reserve0) * uint256(reserve1);

        emit Mint(msg.sender, amount0, amount1);
    }

    // ─── Liquidity: Burn ──────────────────────────────────────────────────────

    /**
     * @notice Remove liquidity and receive underlying tokens.
     * @dev Caller (Router) must transfer LP tokens to this contract
     *      before calling burn(). Underlying tokens sent to `to`.
     *
     * @param to Address that receives token0 and token1.
     * @return amount0 Amount of token0 returned.
     * @return amount1 Amount of token1 returned.
     */
    function burn(address to)
        external
        nonReentrant
        returns (uint256 amount0, uint256 amount1)
    {
        if (to == address(0)) revert ZeroAddress();
        if (to == token0 || to == token1) revert InvalidTo(to);

        (uint112 _reserve0, uint112 _reserve1,) = getReserves();

        uint256 balance0  = IERC20(token0).balanceOf(address(this));
        uint256 balance1  = IERC20(token1).balanceOf(address(this));
        uint256 liquidity = balanceOf(address(this));

        bool feeOn        = _mintProtocolFee(_reserve0, _reserve1);
        uint256 _totalSupply = totalSupply();

        // Proportional redemption
        amount0 = (liquidity * balance0) / _totalSupply;
        amount1 = (liquidity * balance1) / _totalSupply;

        if (amount0 == 0 || amount1 == 0) revert InsufficientLiquidityBurned();

        _burn(address(this), liquidity);

        IERC20(token0).safeTransfer(to, amount0);
        IERC20(token1).safeTransfer(to, amount1);

        balance0 = IERC20(token0).balanceOf(address(this));
        balance1 = IERC20(token1).balanceOf(address(this));

        _update(balance0, balance1, _reserve0, _reserve1);

        if (feeOn) kLast = uint256(reserve0) * uint256(reserve1);

        emit Burn(msg.sender, amount0, amount1, to);
    }

    // ─── Swap ─────────────────────────────────────────────────────────────────

    /**
     * @notice Execute a swap.
     * @dev Caller (Router) must transfer input tokens to this contract
     *      before calling swap(). Output tokens sent to `to`.
     *
     *      SECURITY — TOCTOU prevention:
     *        Operation type is passed explicitly by Router (amount0Out vs
     *        amount1Out). We do NOT infer direction from balance/reserve
     *        delta. This prevents the DEX pair _transfer TOCTOU attack
     *        (defiSKILL: buy vs removeLiquidity / sell vs addLiquidity).
     *
     *      SECURITY — K invariant:
     *        After output transfer, we verify:
     *          balance0Adjusted * balance1Adjusted >= reserve0 * reserve1 * 1000^2
     *        This accounts for the 0.3% fee staying in the pool.
     *        If violated, reverts — prevents flash loan drain.
     *
     * @param amount0Out Amount of token0 to send out (0 if swapping token0 in).
     * @param amount1Out Amount of token1 to send out (0 if swapping token1 in).
     * @param to         Address that receives output tokens.
     */
    function swap(
        uint256 amount0Out,
        uint256 amount1Out,
        address to
    ) external nonReentrant {
        if (amount0Out == 0 && amount1Out == 0) revert InsufficientOutputAmount();
        if (to == address(0)) revert ZeroAddress();
        if (to == token0 || to == token1) revert InvalidTo(to);

        (uint112 _reserve0, uint112 _reserve1,) = getReserves();

        if (amount0Out >= _reserve0 || amount1Out >= _reserve1) {
            revert InsufficientLiquidity();
        }

        // Transfer output tokens to recipient
        if (amount0Out > 0) IERC20(token0).safeTransfer(to, amount0Out);
        if (amount1Out > 0) IERC20(token1).safeTransfer(to, amount1Out);

        // Read post-transfer balances
        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));

        // Derive input amounts from balance delta
        uint256 amount0In = balance0 > _reserve0 - amount0Out
            ? balance0 - (_reserve0 - amount0Out)
            : 0;
        uint256 amount1In = balance1 > _reserve1 - amount1Out
            ? balance1 - (_reserve1 - amount1Out)
            : 0;

        if (amount0In == 0 && amount1In == 0) revert InsufficientInputAmount();

        // Verify constant product invariant with fee adjustment (0.3%)
        // adjusted = balance * 1000 - amountIn * 3
        // invariant: adjusted0 * adjusted1 >= reserve0 * reserve1 * 1000^2
        uint256 balance0Adjusted = balance0 * 1_000 - amount0In * 3;
        uint256 balance1Adjusted = balance1 * 1_000 - amount1In * 3;

        if (
            balance0Adjusted * balance1Adjusted <
            uint256(_reserve0) * uint256(_reserve1) * 1_000_000
        ) {
            revert KInvariantViolated();
        }

        _update(balance0, balance1, _reserve0, _reserve1);

        emit Swap(msg.sender, amount0In, amount1In, amount0Out, amount1Out, to);
    }

    // ─── Sync / Skim ─────────────────────────────────────────────────────────

    /**
     * @notice Force reserves to match current token balances.
     * @dev Called if tokens are sent directly to the pair outside of
     *      normal Router flow (e.g. accidental transfer).
     */
    function sync() external nonReentrant {
        _update(
            IERC20(token0).balanceOf(address(this)),
            IERC20(token1).balanceOf(address(this)),
            reserve0,
            reserve1
        );
    }

    /**
     * @notice Transfer excess tokens (above reserves) to `to`.
     * @dev Safety valve — recovers tokens sent directly to this contract.
     */
    function skim(address to) external nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        IERC20(token0).safeTransfer(
            to,
            IERC20(token0).balanceOf(address(this)) - reserve0
        );
        IERC20(token1).safeTransfer(
            to,
            IERC20(token1).balanceOf(address(this)) - reserve1
        );
    }
}
