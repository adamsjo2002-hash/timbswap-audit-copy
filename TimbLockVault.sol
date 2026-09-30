// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title TimbLockVault
 * @notice Public ERC-20 token locking vault.
 *
 * Model:
 *   - Any address can lock any whitelisted ERC-20 token for 24–320 hours.
 *   - Tokens are held in this contract and returned to the locker after
 *     the unlock timestamp. No early exit permitted.
 *   - All locks are publicly indexed — anyone can read the registry.
 *   - TIMBS locks receive a flag for UI badge/highlight.
 *   - Default whitelist set by owner. Users can permissionlessly add tokens
 *     to their own personal import list (tracked off-chain via events,
 *     not stored on-chain per-user to save gas).
 *   - One active lock per wallet per token at a time. A new lock on the
 *     same token extends/replaces only after the previous one is withdrawn.
 *
 * Lock lifecycle:
 *   Active → Unlocked (after unlock timestamp) → Withdrawn (claimed)
 *
 * Security (defiSKILL):
 *   - ReentrancyGuard on lock(), withdraw().
 *   - Collateral ownership: only the original locker can withdraw.
 *   - SafeERC20 on all transfers — handles non-standard tokens.
 *   - Token whitelist prevents locking arbitrary malicious tokens.
 *   - Balance check before and after transfer — catches fee-on-transfer
 *     tokens and records actual received amount.
 *   - Emergency pause on lock() only — withdrawals always available.
 *   - Owner can permissionlessly add tokens to the global whitelist.
 *
 * Deployment:
 *   1. Deploy TimbLockVault(timbsToken)
 *   2. addToWhitelist([TIMBS, ETH_wrapper, DAPP, LINK])
 *   3. Verify on Sourcify
 */
contract TimbLockVault is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ─── Constants ───────────────────────────────────────────────────────────

    /// @notice Minimum lock duration in seconds (24 hours).
    uint256 public constant MIN_DURATION = 24 hours;

    /// @notice Maximum lock duration in seconds (320 hours).
    uint256 public constant MAX_DURATION = 320 hours;

    // ─── Types ───────────────────────────────────────────────────────────────

    enum LockStatus { Active, Unlocked, Withdrawn }

    struct LockEntry {
        uint256 lockId;         // Global sequential lock ID
        address locker;         // Address that created the lock
        address token;          // ERC-20 token locked
        uint256 amount;         // Actual amount received (after fee-on-transfer)
        uint256 lockedAt;       // block.timestamp at lock creation
        uint256 unlockAt;       // block.timestamp when withdrawable
        LockStatus status;      // Current lifecycle status
        bool isTimbs;           // True if locked token is TIMBS (UI badge)
    }

    // ─── State ───────────────────────────────────────────────────────────────

    /// @notice TIMBS token address — locks of this token get isTimbs flag.
    address public immutable timbsToken;

    /// @notice Global lock ID counter.
    uint256 public nextLockId;

    /// @notice All locks by ID.
    mapping(uint256 => LockEntry) public locks;

    /// @notice locker → token → active lockId (0 = none).
    ///         Enforces one active lock per wallet per token.
    mapping(address => mapping(address => uint256)) public activeLockId;

    /// @notice Global whitelist of tokens allowed to be locked.
    mapping(address => bool) public tokenWhitelist;

    /// @notice All whitelisted token addresses (for enumeration).
    address[] public whitelistedTokens;

    /// @notice All lock IDs created by an address (history).
    mapping(address => uint256[]) public lockerHistory;

    /// @notice Emergency pause on lock() — withdrawals always permitted.
    bool public lockingPaused;

    // ─── Events ──────────────────────────────────────────────────────────────

    event Locked(
        uint256 indexed lockId,
        address indexed locker,
        address indexed token,
        uint256 amount,
        uint256 unlockAt,
        bool isTimbs
    );
    event Withdrawn(
        uint256 indexed lockId,
        address indexed locker,
        address indexed token,
        uint256 amount
    );
    event TokenWhitelisted(address indexed token, bool allowed);
    event LockingPaused(address indexed by);
    event LockingUnpaused(address indexed by);

    // ─── Errors ──────────────────────────────────────────────────────────────

    error ZeroAmount();
    error ZeroAddress();
    error TokenNotWhitelisted(address token);
    error DurationTooShort(uint256 provided, uint256 minimum);
    error DurationTooLong(uint256 provided, uint256 maximum);
    error ActiveLockExists(uint256 existingLockId);
    error LockNotFound(uint256 lockId);
    error NotLocker(address caller, address locker);
    error LockNotUnlocked(uint256 unlockAt, uint256 currentTime);
    error AlreadyWithdrawn(uint256 lockId);
    error LockingCurrentlyPaused();
    error TransferAmountMismatch();

    // ─── Constructor ─────────────────────────────────────────────────────────

    /**
     * @param _timbsToken TIMBS token address — locks of this get isTimbs flag.
     */
    constructor(address _timbsToken) Ownable(msg.sender) {
        if (_timbsToken == address(0)) revert ZeroAddress();
        timbsToken = _timbsToken;

        // TIMBS is whitelisted by default
        _addToWhitelist(_timbsToken);

        // IDs start at 1 — 0 is the sentinel "no active lock" value
        nextLockId = 1;
    }

    // ─── Lock ─────────────────────────────────────────────────────────────────

    /**
     * @notice Lock `amount` of `token` for `durationSeconds`.
     * @dev Tokens transferred to this contract and held until unlockAt.
     *      Balance check before/after transfer records actual received amount
     *      — handles fee-on-transfer tokens correctly.
     *      One active lock per wallet per token enforced.
     *
     * @param token           ERC-20 token to lock (must be whitelisted).
     * @param amount          Amount to lock (pre-transfer, in token decimals).
     * @param durationSeconds Lock duration in seconds (24h–320h).
     * @return lockId         The assigned lock ID.
     */
    function lock(
        address token,
        uint256 amount,
        uint256 durationSeconds
    )
        external
        nonReentrant
        returns (uint256 lockId)
    {
        if (lockingPaused) revert LockingCurrentlyPaused();
        if (token  == address(0)) revert ZeroAddress();
        if (amount == 0)          revert ZeroAmount();
        if (!tokenWhitelist[token]) revert TokenNotWhitelisted(token);

        if (durationSeconds < MIN_DURATION) {
            revert DurationTooShort(durationSeconds, MIN_DURATION);
        }
        if (durationSeconds > MAX_DURATION) {
            revert DurationTooLong(durationSeconds, MAX_DURATION);
        }

        // Enforce one active lock per wallet per token
        uint256 existingId = activeLockId[msg.sender][token];
        if (existingId != 0) {
            LockEntry storage existing = locks[existingId];
            if (existing.status == LockStatus.Active) {
                revert ActiveLockExists(existingId);
            }
        }

        // Balance check before transfer — records actual received amount
        uint256 balanceBefore = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        uint256 balanceAfter  = IERC20(token).balanceOf(address(this));
        uint256 actualAmount  = balanceAfter - balanceBefore;

        if (actualAmount == 0) revert ZeroAmount();

        lockId = nextLockId++;
        uint256 unlockAt = block.timestamp + durationSeconds;

        locks[lockId] = LockEntry({
            lockId:   lockId,
            locker:   msg.sender,
            token:    token,
            amount:   actualAmount,
            lockedAt: block.timestamp,
            unlockAt: unlockAt,
            status:   LockStatus.Active,
            isTimbs:  token == timbsToken
        });

        activeLockId[msg.sender][token] = lockId;
        lockerHistory[msg.sender].push(lockId);

        emit Locked(lockId, msg.sender, token, actualAmount, unlockAt, token == timbsToken);
    }

    // ─── Withdraw ─────────────────────────────────────────────────────────────

    /**
     * @notice Withdraw tokens from a lock after the unlock timestamp.
     * @dev Only the original locker can withdraw.
     *      Withdrawals always permitted regardless of lockingPaused.
     * @param lockId The lock ID to withdraw from.
     */
    function withdraw(uint256 lockId) external nonReentrant {
        LockEntry storage entry = locks[lockId];

        if (entry.locker == address(0))      revert LockNotFound(lockId);
        if (entry.locker != msg.sender)      revert NotLocker(msg.sender, entry.locker);
        if (entry.status == LockStatus.Withdrawn) revert AlreadyWithdrawn(lockId);
        if (block.timestamp < entry.unlockAt) {
            revert LockNotUnlocked(entry.unlockAt, block.timestamp);
        }

        entry.status = LockStatus.Withdrawn;
        activeLockId[msg.sender][entry.token] = 0;

        IERC20(entry.token).safeTransfer(msg.sender, entry.amount);

        emit Withdrawn(lockId, msg.sender, entry.token, entry.amount);
    }

    // ─── Owner: Whitelist ─────────────────────────────────────────────────────

    /**
     * @notice Add a token to the global lock whitelist.
     */
    function addToWhitelist(address token) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        _addToWhitelist(token);
    }

    /**
     * @notice Add multiple tokens to whitelist in one call.
     */
    function addManyToWhitelist(address[] calldata tokens) external onlyOwner {
        for (uint256 i = 0; i < tokens.length; i++) {
            if (tokens[i] != address(0)) {
                _addToWhitelist(tokens[i]);
            }
        }
    }

    /**
     * @notice Remove a token from the whitelist.
     * @dev Existing locks of this token are unaffected — only new locks blocked.
     */
    function removeFromWhitelist(address token) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        tokenWhitelist[token] = false;
        emit TokenWhitelisted(token, false);
    }

    function _addToWhitelist(address token) internal {
        if (!tokenWhitelist[token]) {
            tokenWhitelist[token] = true;
            whitelistedTokens.push(token);
            emit TokenWhitelisted(token, true);
        }
    }

    // ─── Owner: Pause ─────────────────────────────────────────────────────────

    /**
     * @notice Pause new lock creation. Withdrawals always available.
     */
    function pauseLocking() external onlyOwner {
        lockingPaused = true;
        emit LockingPaused(msg.sender);
    }

    function unpauseLocking() external onlyOwner {
        lockingPaused = false;
        emit LockingUnpaused(msg.sender);
    }

    // ─── View: Registry ───────────────────────────────────────────────────────

    /**
     * @notice Returns a lock entry by ID.
     */
    function getLock(uint256 lockId)
        external
        view
        returns (LockEntry memory)
    {
        return locks[lockId];
    }

    /**
     * @notice Returns all lock IDs created by `locker`.
     */
    function getLockerHistory(address locker)
        external
        view
        returns (uint256[] memory)
    {
        return lockerHistory[locker];
    }

    /**
     * @notice Returns all lock entries for a locker (full history).
     * @dev Potentially large — use off-chain indexing for production UI.
     */
    function getLockerLocks(address locker)
        external
        view
        returns (LockEntry[] memory entries)
    {
        uint256[] memory ids = lockerHistory[locker];
        entries = new LockEntry[](ids.length);
        for (uint256 i = 0; i < ids.length; i++) {
            entries[i] = locks[ids[i]];
        }
    }

    /**
     * @notice Returns the active lock for a wallet + token combination.
     *         Returns an empty struct if no active lock exists.
     */
    function getActiveLock(address locker, address token)
        external
        view
        returns (LockEntry memory)
    {
        uint256 id = activeLockId[locker][token];
        if (id == 0) return LockEntry(0, address(0), address(0), 0, 0, 0, LockStatus.Withdrawn, false);
        return locks[id];
    }

    /**
     * @notice Returns all whitelisted token addresses.
     */
    function getWhitelistedTokens()
        external
        view
        returns (address[] memory)
    {
        return whitelistedTokens;
    }

    /**
     * @notice Returns total number of locks ever created.
     */
    function totalLocks() external view returns (uint256) {
        return nextLockId - 1;
    }

    /**
     * @notice Returns time remaining until a lock can be withdrawn.
     *         Returns 0 if already unlocked.
     */
    function timeUntilUnlock(uint256 lockId)
        external
        view
        returns (uint256)
    {
        LockEntry storage entry = locks[lockId];
        if (entry.locker == address(0)) revert LockNotFound(lockId);
        if (block.timestamp >= entry.unlockAt) return 0;
        return entry.unlockAt - block.timestamp;
    }
}
