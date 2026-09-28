// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title EligibleTokenRegistry
 * @notice Shared registry of tokens eligible to influence the TimbSwap
 *         prize game scroll position via swap activity.
 *
 * Purpose:
 *   - Single source of truth for eligible token list.
 *   - Consumed by TimbSwapRouter (before nudgeScroll call) and
 *     TimbPrize (for validation at settlement).
 *   - Decoupled from both contracts — list can be updated without
 *     redeploying Router or TimbPrize.
 *
 * Eligible tokens at launch:
 *   - TIMBS (TimbSwap native token)
 *   - ETH / WETH
 *   - DAPP (existing ecosystem token)
 *   - Owner-extendable at any time.
 *
 * Authorised callers:
 *   - Owner: add/remove tokens.
 *   - Any address: read isEligible() — public view.
 *   - Registered consumers (Router, TimbPrize): no special permissions
 *     needed — reads are permissionless.
 *
 * Security:
 *   - Owner-only writes. No reentrancy risk (no token transfers).
 *   - Removing a token mid-round does not retroactively invalidate
 *     scroll nudges already recorded — those are final on-chain.
 *   - Adding a token takes effect immediately for future swaps.
 *
 * Deployment:
 *   1. Deploy EligibleTokenRegistry(initialTokens[])
 *   2. router.setEligibleRegistry(address(this))
 *   3. timbPrize.setEligibleRegistry(address(this)) (after TimbPrize deploy)
 *   4. Verify on Sourcify
 */
contract EligibleTokenRegistry is Ownable {

    // ─── State ───────────────────────────────────────────────────────────────

    /// @notice token address → eligible for swap influence.
    mapping(address => bool) public isEligible;

    /// @notice Ordered list of all ever-added eligible tokens.
    ///         Tokens removed from eligibility remain in the array
    ///         but isEligible[token] == false.
    address[] public eligibleTokenList;

    /// @notice Registered consumer contracts (Router, TimbPrize).
    ///         Informational — reads are permissionless so no enforcement
    ///         needed, but tracked for transparency and frontend queries.
    mapping(address => bool) public registeredConsumers;
    address[] public consumerList;

    // ─── Events ──────────────────────────────────────────────────────────────

    event TokenAdded(address indexed token);
    event TokenRemoved(address indexed token);
    event ConsumerRegistered(address indexed consumer);
    event ConsumerRemoved(address indexed consumer);

    // ─── Errors ──────────────────────────────────────────────────────────────

    error ZeroAddress();
    error AlreadyEligible(address token);
    error NotEligible(address token);
    error AlreadyRegistered(address consumer);
    error NotRegistered(address consumer);

    // ─── Constructor ─────────────────────────────────────────────────────────

    /**
     * @param initialTokens Array of token addresses eligible at deploy.
     *                      Typically: [TIMBS, WETH, DAPP].
     */
    constructor(address[] memory initialTokens) Ownable(msg.sender) {
        for (uint256 i = 0; i < initialTokens.length; i++) {
            if (initialTokens[i] != address(0)) {
                _addToken(initialTokens[i]);
            }
        }
    }

    // ─── Owner: Token Management ──────────────────────────────────────────────

    /**
     * @notice Add a token to the eligible list.
     * @param token ERC-20 token address to add.
     */
    function addToken(address token) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        if (isEligible[token])   revert AlreadyEligible(token);
        _addToken(token);
    }

    /**
     * @notice Add multiple tokens in one call.
     * @param tokens Array of token addresses.
     */
    function addTokens(address[] calldata tokens) external onlyOwner {
        for (uint256 i = 0; i < tokens.length; i++) {
            if (tokens[i] == address(0)) revert ZeroAddress();
            if (!isEligible[tokens[i]]) {
                _addToken(tokens[i]);
            }
        }
    }

    /**
     * @notice Remove a token from the eligible list.
     * @dev Does not remove from eligibleTokenList array (history preserved).
     *      Sets isEligible[token] = false — takes effect immediately.
     * @param token Token address to remove.
     */
    function removeToken(address token) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        if (!isEligible[token])  revert NotEligible(token);
        isEligible[token] = false;
        emit TokenRemoved(token);
    }

    function _addToken(address token) internal {
        isEligible[token] = true;
        eligibleTokenList.push(token);
        emit TokenAdded(token);
    }

    // ─── Owner: Consumer Registry ─────────────────────────────────────────────

    /**
     * @notice Register a consumer contract (Router, TimbPrize).
     *         Informational — tracks which contracts read this registry.
     */
    function registerConsumer(address consumer) external onlyOwner {
        if (consumer == address(0))        revert ZeroAddress();
        if (registeredConsumers[consumer]) revert AlreadyRegistered(consumer);
        registeredConsumers[consumer] = true;
        consumerList.push(consumer);
        emit ConsumerRegistered(consumer);
    }

    /**
     * @notice Remove a consumer from the registry.
     */
    function removeConsumer(address consumer) external onlyOwner {
        if (!registeredConsumers[consumer]) revert NotRegistered(consumer);
        registeredConsumers[consumer] = false;
        emit ConsumerRemoved(consumer);
    }

    // ─── View ─────────────────────────────────────────────────────────────────

    /**
     * @notice Returns all currently eligible token addresses.
     * @dev Filters out removed tokens. May be expensive for large lists —
     *      use off-chain indexing for production UIs.
     */
    function getEligibleTokens()
        external
        view
        returns (address[] memory eligible)
    {
        uint256 count = 0;
        for (uint256 i = 0; i < eligibleTokenList.length; i++) {
            if (isEligible[eligibleTokenList[i]]) count++;
        }
        eligible = new address[](count);
        uint256 idx = 0;
        for (uint256 i = 0; i < eligibleTokenList.length; i++) {
            if (isEligible[eligibleTokenList[i]]) {
                eligible[idx++] = eligibleTokenList[i];
            }
        }
    }

    /**
     * @notice Returns total number of tokens ever added (including removed).
     */
    function totalTokensAdded() external view returns (uint256) {
        return eligibleTokenList.length;
    }

    /**
     * @notice Returns all registered consumer contracts.
     */
    function getConsumers() external view returns (address[] memory) {
        return consumerList;
    }

    /**
     * @notice Batch eligibility check — returns bool array matching input.
     * @dev Useful for frontend to check multiple tokens in one call.
     */
    function areEligible(address[] calldata tokens)
        external
        view
        returns (bool[] memory results)
    {
        results = new bool[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            results[i] = isEligible[tokens[i]];
        }
    }
}
