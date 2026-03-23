// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./LPToken.sol";
import "./FeeCollector.sol";
import "./PoolFactory.sol";

/**
 * @title SwapPool
 * @notice Holds Polymarket ERC-1155 shares and WrappedOpinion ERC-1155 shares
 *         for ONE specific event-outcome pair. Both sides represent the same
 *         real-world outcome and are treated as 1:1 equivalent in value.
 *
 *         Token contract addresses are read from PoolFactory (single source of truth).
 *         Only token IDs differ per pool.
 *
 *         Deployed by PoolFactory. One pool per matched market pair.
 *
 * ─── Two LP tokens ────────────────────────────────────────────────────────────
 *
 *   polyLpToken   — minted when depositing Polymarket shares
 *   opinionLpToken — minted when depositing WrappedOpinion shares
 *
 *   Both LP tokens share a single unified exchange rate:
 *     rate = totalShares() / totalLpSupply()
 *
 *   The LP token type records which side a user deposited from, which
 *   determines same-side vs cross-side withdrawal rules. It does NOT
 *   affect the exchange rate — all LP holders earn fees equally.
 *
 * ─── Pool Mechanics ───────────────────────────────────────────────────────────
 *
 *   totalLpSupply = polyLpToken.totalSupply() + opinionLpToken.totalSupply()
 *   rate          = totalShares() / totalLpSupply()
 *   lpToMint      = depositAmount * totalLpSupply / totalShares  (or 1:1 if first)
 *   sharesOut     = lpBurned * totalShares / totalLpSupply
 *
 * ─── Withdrawal rules ─────────────────────────────────────────────────────────
 *
 *   Same-side  (burn polyLP → receive Poly, or burn opinionLP → receive Opinion):
 *     Free, instant, no fee.
 *
 *   Cross-side (burn polyLP → receive Opinion, or burn opinionLP → receive Poly):
 *     Swap fee applies (LP fee + protocol fee), same as swap().
 *     After pool is marked resolved: cross-side is also free (market settled).
 *
 * ─── Swap fee ─────────────────────────────────────────────────────────────────
 *
 *   0.40% total (configurable in factory, capped by hard limits)
 *     0.30% LP fee      → stays in pool on fromSide / receiveSide (auto-compounds)
 *     0.10% protocol fee → transferred to FeeCollector
 *
 * ─── Side Enum ────────────────────────────────────────────────────────────────
 *
 *   Side.POLYMARKET  = native Polymarket ERC-1155 shares
 *   Side.OPINION     = WrappedOpinion ERC-1155 shares (bridged from BSC)
 */
contract SwapPool is ERC1155Holder, ReentrancyGuard {

    using SafeERC20 for IERC20;
    
    // ─── Immutable config ─────────────────────────────────────────────────────

    /// @notice Precision scalar for exchange rate fixed-point arithmetic.
    uint256 private constant RATE_PRECISION = 1e18;

    /// @notice Factory that deployed this pool — source of token contract addresses and fees
    PoolFactory public immutable factory;

    /// @notice Polymarket ERC-1155 token ID for this pool's event-outcome
    uint256 public immutable polymarketTokenId;
    /// @notice WrappedOpinion ERC-1155 token ID for this pool's event-outcome
    uint256 public immutable opinionTokenId;

    /// @notice LP token for Polymarket depositors
    LPToken public immutable polyLpToken;
    /// @notice LP token for Opinion depositors
    LPToken public immutable opinionLpToken;

    /// @notice Protocol fee recipient
    FeeCollector public immutable feeCollector;

    // ─── Pool state ───────────────────────────────────────────────────────────

    /// @notice Polymarket shares held in this pool
    uint256 public polymarketBalance;
    /// @notice WrappedOpinion shares held in this pool
    uint256 public opinionBalance;

    /// @notice Set to true once the underlying market resolves.
    ///         After resolution cross-side withdrawals are fee-free.
    bool public resolved;

    bool public depositsPaused;
    bool public swapsPaused;

    // ─── Types ────────────────────────────────────────────────────────────────

    enum Side {
        POLYMARKET,
        OPINION
    }

    // ─── Events ───────────────────────────────────────────────────────────────

    event DepositsPausedSet(bool isPaused);
    event SwapsPausedSet(bool isPaused);
    event Resolved(bool isResolved);    

    event Deposited(address indexed user, Side side, uint256 sharesIn, uint256 lpMinted);

    /// @notice Emitted on every withdrawal, same-side or cross-side.
    ///         lpFee and protocolFee are zero for same-side or post-resolution withdrawals.
    event WithdrawnSingleSide(
        address indexed user,
        Side lpSide,
        Side receiveSide,
        uint256 lpBurned,
        uint256 sharesOut,
        uint256 lpFee,
        uint256 protocolFee
    );

    event WithdrawnBothSides(
        address indexed user,
        Side lpSide,
        uint256 lpBurned,
        uint256 samesideOut,
        uint256 crosssideOut,
        uint256 crossLpFee,
        uint256 crossProtocolFee
    );

    event Swapped(
        address indexed user,
        Side fromSide,
        uint256 amountIn,
        uint256 amountOut,
        uint256 lpFee,
        uint256 protocolFee
    );

    event TokensRescued(Side side, uint256 amount, address indexed to);
    event ERC1155Rescued(address indexed token, uint256 tokenId, uint256 amount, address indexed to);
    event ERC20Rescued(address indexed token, uint256 amount, address indexed to);
    event ETHRescued(uint256 amount, address indexed to);

    // ─── Errors ───────────────────────────────────────────────────────────────

    error DepositsPaused();
    error SwapsPaused();
    error AlreadyResolved();
    error NotResolved();
    error InvalidSplit();
    error ZeroAmount();
    error ZeroAddress();
    error InvalidTokenID();
    error DepositTooSmall();
    error Unauthorized();
    error NothingToRescue();
    error CannotRescuePoolTokens();
    error InsufficientLiquidity(uint256 available, uint256 required);

    // ─── Constructor ──────────────────────────────────────────────────────────

    constructor(
        address factory_,
        uint256 polymarketTokenId_,
        uint256 opinionTokenId_,
        address polyLpToken_,
        address opinionLpToken_,
        address feeCollector_
    ) {
        if (
            factory_ == address(0) ||
            polyLpToken_ == address(0) ||
            opinionLpToken_ == address(0) ||
            feeCollector_ == address(0)
        ) revert ZeroAddress();

        if (polymarketTokenId_ == 0 || opinionTokenId_ == 0) revert InvalidTokenID();

        factory = PoolFactory(factory_);
        polymarketTokenId = polymarketTokenId_;
        opinionTokenId = opinionTokenId_;
        polyLpToken = LPToken(polyLpToken_);
        opinionLpToken = LPToken(opinionLpToken_);
        feeCollector = FeeCollector(feeCollector_);
    }

    // ─── View helpers ─────────────────────────────────────────────────────────

    /// @notice Total shares across both sides
    function totalShares() public view returns (uint256) {
        return polymarketBalance + opinionBalance;
    }

    /// @notice Combined supply of both LP tokens — used as the unified denominator
    function totalLpSupply() public view returns (uint256) {
        return polyLpToken.totalSupply() + opinionLpToken.totalSupply();
    }

    /**
     * @notice Current LP exchange rate scaled by 1e18.
     *         rate = totalShares / totalLpSupply
     *         Returns 1e18 when pool is empty (first deposit rate).
     *         Both LP token types share this same rate.
     */
    function exchangeRate() public view returns (uint256) {
        uint256 supply = totalLpSupply();
        if (supply == 0) return RATE_PRECISION;
        return (totalShares() * RATE_PRECISION) / supply;
    }

    // ─── Fee helper ───────────────────────────────────────────────────────────

    /**
     * @notice Compute LP fee and protocol fee using ceiling division.
     *         Ceiling division ensures any non-zero amount with non-zero bps
     *         pays at least 1 unit of fee, preventing fee evasion via splitting.
     *
     * @param amount     Gross share amount subject to fees
     * @return lpFee     Fee retained by the pool (auto-compounds for LPs)
     * @return protocolFee Fee transferred to FeeCollector
     */
    function _computeFees(uint256 amount) internal view returns (uint256 lpFee, uint256 protocolFee) {
        uint256 denom = factory.FEE_DENOMINATOR();
        uint256 lbps  = factory.lpFeeBps();
        uint256 pbps  = factory.protocolFeeBps();

        // Ceiling division: (a * b + denom - 1) / denom
        // When bps == 0 (fee disabled), result is 0 — the guard is defensive.
        lpFee       = lbps > 0 ? (amount * lbps  + denom - 1) / denom : 0;
        protocolFee = pbps > 0 ? (amount * pbps  + denom - 1) / denom : 0;
    }

    // ─── Deposit ──────────────────────────────────────────────────────────────

    /**
     * @notice Deposit shares into the pool and receive the matching LP token.
     *         Depositing Polymarket shares mints polyLpToken.
     *         Depositing Opinion shares mints opinionLpToken.
     *         Both LP tokens use the same unified exchange rate.
     *
     * @param side    Which token to deposit (POLYMARKET or OPINION)
     * @param amount  Number of ERC-1155 shares to deposit
     */
    function deposit(Side side, uint256 amount) external nonReentrant returns (uint256 lpMinted) {
        if (depositsPaused) revert DepositsPaused();
        if (amount == 0) revert ZeroAmount();

        _pullTokens(side, msg.sender, amount);

        uint256 supply = totalLpSupply();
        if (supply == 0) {
            // First depositor across either side: 1 share = 1 LP token
            lpMinted = amount;
        } else {
            // Use totalShares() before updating balance
            lpMinted = (amount * supply) / totalShares();
        }

        if (lpMinted == 0) revert DepositTooSmall();

        _updateBalance(side, amount, true);
        _lpToken(side).mint(msg.sender, lpMinted);

        emit Deposited(msg.sender, side, amount, lpMinted);
    }

    // ─── Withdraw ─────────────────────────────────────────────────────────────

    /**
     * @notice Burn LP tokens and receive underlying shares.
     *
     *         lpSide      — which LP token to burn (matches the side originally deposited)
     *         receiveSide — which ERC-1155 token to receive
     *
     *         Same-side   (lpSide == receiveSide): free, no fee.
     *         Cross-side  (lpSide != receiveSide): swap fee deducted from sharesOut,
     *                     unless the pool is marked resolved (fee-free after resolution).
     *
     * @param lpAmount     LP tokens to burn
     * @param lpSide       Side of LP token to burn (POLYMARKET or OPINION)
     * @param receiveSide  Side of ERC-1155 shares to receive
     */
    function withdrawSingleSide(
        uint256 lpAmount,
        Side lpSide,
        Side receiveSide
    ) external nonReentrant returns (uint256 sharesReceived) {
        if (lpAmount == 0) revert ZeroAmount();

        uint256 sharesOut = (lpAmount * totalShares()) / totalLpSupply();

        // Burn LP first (CEI pattern)
        _lpToken(lpSide).burn(msg.sender, lpAmount);

        uint256 lpFee;
        uint256 protocolFee;
        uint256 actualOut;

        if (lpSide == receiveSide) {
            // ── Same-side: free ──────────────────────────────────────────────
            uint256 avail = _getBalance(receiveSide);
            if (sharesOut > avail) revert InsufficientLiquidity(avail, sharesOut);

            _updateBalance(receiveSide, sharesOut, false);
            _pushTokens(receiveSide, msg.sender, sharesOut);

            sharesReceived = sharesOut;
            _flushResidualIfEmpty();
            emit WithdrawnSingleSide(msg.sender, lpSide, receiveSide, lpAmount, sharesOut, 0, 0);
        } else {
            // ── Cross-side ───────────────────────────────────────────────────
            if (swapsPaused) revert SwapsPaused();
            uint256 avail = _getBalance(receiveSide);

            if (resolved) {
                // After resolution: cross-side is also free
                if (sharesOut > avail) revert InsufficientLiquidity(avail, sharesOut);
                actualOut = sharesOut;                
                _updateBalance(receiveSide, actualOut, false);
                _pushTokens(receiveSide, msg.sender, actualOut);
            } else {
                // Ceiling division: any non-zero sharesOut pays at least 1 unit of fee
                (lpFee, protocolFee) = _computeFees(sharesOut);
                actualOut = sharesOut - lpFee - protocolFee;

                // lpFee stays in receiveSide balance implicitly (only subtract actualOut + protocolFee)    
                if (actualOut + protocolFee > avail) revert InsufficientLiquidity(avail, actualOut + protocolFee);
                _updateBalance(receiveSide, actualOut + protocolFee, false);
                _pushTokens(receiveSide, msg.sender, actualOut);

                if (protocolFee > 0) {
                    _pushTokens(receiveSide, address(feeCollector), protocolFee);
                    feeCollector.recordFee(_tokenAddress(receiveSide), _tokenId(receiveSide), protocolFee);
                }
            }
            sharesReceived = actualOut;
            _flushResidualIfEmpty();
            emit WithdrawnSingleSide(msg.sender, lpSide, receiveSide, lpAmount, actualOut, lpFee, protocolFee);
        }
    }

    function withdrawBothSides(
        uint256 lpAmount,
        Side lpSide,
        uint256 samesideBps    // e.g. 5000 = 50% same-side, 5000 = 50% cross-side
    ) external nonReentrant returns (uint256 samesideReceived, uint256 crosssideReceived) {
        if (lpAmount == 0) revert ZeroAmount();
        if (samesideBps > factory.FEE_DENOMINATOR()) revert InvalidSplit();

        uint256 grossOut = (lpAmount * totalShares()) / totalLpSupply();

        uint256 samesideAmount = (grossOut * samesideBps) / factory.FEE_DENOMINATOR();
        uint256 crosssideAmount = grossOut - samesideAmount;

        _lpToken(lpSide).burn(msg.sender, lpAmount);

        Side sameSide  = lpSide;
        Side crossSide = _oppositeSide(lpSide);

        // Same-side: free
        if (samesideAmount > 0) {
            uint256 avail = _getBalance(sameSide);
            if (samesideAmount > avail) revert InsufficientLiquidity(avail, samesideAmount);
            _updateBalance(sameSide, samesideAmount, false);
            _pushTokens(sameSide, msg.sender, samesideAmount);
            samesideReceived = samesideAmount;
        }

        // Cross-side: fee applies
        uint256 crossActualOut;
        uint256 crossLpFee;
        uint256 crossProtocolFee;

        if (crosssideAmount > 0) {
            if (swapsPaused) revert SwapsPaused(); 
            uint256 avail = _getBalance(crossSide);            

            if (resolved) {
                // After resolution: cross-side is also free
                if (crosssideAmount > avail) revert InsufficientLiquidity(avail, crosssideAmount);
                crossActualOut = crosssideAmount;
                _updateBalance(crossSide, crossActualOut, false);
                _pushTokens(crossSide, msg.sender, crossActualOut);
            } else {
                // Ceiling division: any non-zero crosssideAmount pays at least 1 unit of fee
                (crossLpFee, crossProtocolFee) = _computeFees(crosssideAmount);
                crossActualOut = crosssideAmount - crossLpFee - crossProtocolFee;
                
                // lpFee stays in crossSide balance implicitly (only subtract crossActualOut + crossProtocolFee)
                if (crossActualOut + crossProtocolFee > avail) revert InsufficientLiquidity(avail, crossActualOut + crossProtocolFee);                
                _updateBalance(crossSide, crossActualOut + crossProtocolFee, false);
                _pushTokens(crossSide, msg.sender, crossActualOut);

                if (crossProtocolFee > 0) {
                    _pushTokens(crossSide, address(feeCollector), crossProtocolFee);
                    feeCollector.recordFee(_tokenAddress(crossSide), _tokenId(crossSide), crossProtocolFee);
                }
            }
        }
        crosssideReceived = crossActualOut;
        _flushResidualIfEmpty();
        emit WithdrawnBothSides(msg.sender, lpSide, lpAmount, samesideAmount, crossActualOut, crossLpFee, crossProtocolFee);
    }

    /// @dev If the last LP just exited, any residual tracked balance (orphaned LP fees)
    ///      is flushed to the feeCollector. Prevents first-depositor capture of fee residue.
    function _flushResidualIfEmpty() internal {
        if (totalLpSupply() > 0) return;

        if (polymarketBalance > 0) {
            uint256 amount = polymarketBalance;
            polymarketBalance = 0;
            _pushTokens(Side.POLYMARKET, address(feeCollector), amount);
            feeCollector.recordFee(factory.polymarketToken(), polymarketTokenId, amount);
        }
        if (opinionBalance > 0) {
            uint256 amount = opinionBalance;
            opinionBalance = 0;
            _pushTokens(Side.OPINION, address(feeCollector), amount);
            feeCollector.recordFee(factory.opinionToken(), opinionTokenId, amount);
        }
    }

    // ─── Swap ─────────────────────────────────────────────────────────────────

    /**
     * @notice Swap shares from one side to the other.
     *         User deposits `fromSide` shares, receives `toSide` shares minus fee.
     *
     *         Fee split:
     *           LP fee       → stays in pool on fromSide (auto-compounds for all LP holders)
     *           Protocol fee → transferred to FeeCollector
     *
     * @param fromSide  Side being deposited
     * @param sharesIn  Number of shares deposited
     */
    function swap(Side fromSide, uint256 sharesIn) external nonReentrant returns (uint256 sharesOut) {
        if (swapsPaused) revert SwapsPaused();
        if (sharesIn == 0) revert ZeroAmount();

        Side toSide = _oppositeSide(fromSide);

        // Ceiling division: any non-zero sharesIn pays at least 1 unit of fee
        (uint256 lpFee, uint256 protocolFee) = _computeFees(sharesIn);
        sharesOut = sharesIn - lpFee - protocolFee;

        uint256 toBalance = _getBalance(toSide);
        if (sharesOut > toBalance) revert InsufficientLiquidity(toBalance, sharesOut);

        _pullTokens(fromSide, msg.sender, sharesIn);

        if (protocolFee > 0) {
            _pushTokens(fromSide, address(feeCollector), protocolFee);
            feeCollector.recordFee(_tokenAddress(fromSide), _tokenId(fromSide), protocolFee);
        }

        _pushTokens(toSide, msg.sender, sharesOut);

        // LP fee stays in fromSide balance (sharesIn - protocolFee added, not sharesIn - protocolFee - lpFee)
        _updateBalance(fromSide, sharesIn - protocolFee, true);
        _updateBalance(toSide, sharesOut, false);

        emit Swapped(msg.sender, fromSide, sharesIn, sharesOut, lpFee, protocolFee);
    }

    // ─── Admin ────────────────────────────────────────────────────────────────

    function setDepositsPaused(bool paused_) external {
        if (msg.sender != address(factory)) revert Unauthorized();
        depositsPaused = paused_;
        emit DepositsPausedSet(paused_);
    }

    function setSwapsPaused(bool paused_) external {
        if (msg.sender != address(factory)) revert Unauthorized();
        swapsPaused = paused_;
        emit SwapsPausedSet(paused_);
    }

    /// @notice Mark this pool as resolved. Cross-side withdrawals become fee-free.
    ///         Called by factory (owner-gated) once the underlying market settles.
    function setResolvedAndPausedDeposits() external {
        if (msg.sender != address(factory)) revert Unauthorized();
        if (resolved) revert AlreadyResolved();
        resolved = true;
        depositsPaused = true;          
        emit Resolved(resolved);
        emit DepositsPausedSet(depositsPaused);
    }

    function unsetResolved() external {
        if (msg.sender != address(factory)) revert Unauthorized();
        if (!resolved) revert NotResolved();
        resolved = false;
        emit Resolved(resolved);
    }


    // ─── Rescue ───────────────────────────────────────────────────────────────

    /// @notice Recover surplus pool tokens sent directly without using deposit().
    ///         Only the untracked surplus above the pool's accounting is rescuable.
    ///         LP holder funds are never at risk.
    function rescueTokens(Side side, uint256 amount, address to) external {
        if (msg.sender != address(factory)) revert Unauthorized();
        if (to == address(0)) revert ZeroAddress();

        uint256 tracked = _getBalance(side);
        uint256 actual = IERC1155(_tokenAddress(side)).balanceOf(address(this), _tokenId(side));
        uint256 surplus = actual - tracked;
        if (amount > surplus) revert NothingToRescue();

        _pushTokens(side, to, amount);
        emit TokensRescued(side, amount, to);
    }

    /// @notice Recover any other ERC-1155 token accidentally sent to this contract.
    ///         Reverts if token is the pool's own Polymarket or Opinion token
    ///         (use rescueTokens for those).
    function rescueERC1155(address token, uint256 tokenId, uint256 amount, address to) external {
        if (msg.sender != address(factory)) revert Unauthorized();
        if (to == address(0)) revert ZeroAddress();
        if (token == factory.polymarketToken() || token == factory.opinionToken())
            revert CannotRescuePoolTokens();
        IERC1155(token).safeTransferFrom(address(this), to, tokenId, amount, "");
        emit ERC1155Rescued(token, tokenId, amount, to);
    }

    /// @notice Recover any ERC-20 token accidentally sent to this contract.
    function rescueERC20(address token, uint256 amount, address to) external {
        if (msg.sender != address(factory)) revert Unauthorized();
        if (to == address(0)) revert ZeroAddress();
        IERC20(token).safeTransfer(to, amount);
        emit ERC20Rescued(token, amount, to);
    }

    /// @notice Recover ETH accidentally sent to this contract.
    function rescueETH(address payable to) external {
        if (msg.sender != address(factory)) revert Unauthorized();
        if (to == address(0)) revert ZeroAddress();
        uint256 balance = address(this).balance;
        (bool ok,) = to.call{value: balance}("");
        require(ok, "ETH transfer failed");
        emit ETHRescued(balance, to);
    }

    receive() external payable {}

    // ─── Internal helpers ─────────────────────────────────────────────────────

    function _pullTokens(Side side, address from, uint256 amount) internal {
        IERC1155(_tokenAddress(side)).safeTransferFrom(from, address(this), _tokenId(side), amount, "");
    }

    function _pushTokens(Side side, address to, uint256 amount) internal {
        IERC1155(_tokenAddress(side)).safeTransferFrom(address(this), to, _tokenId(side), amount, "");
    }

    function _updateBalance(Side side, uint256 amount, bool add) internal {
        if (side == Side.POLYMARKET) {
            polymarketBalance = add ? polymarketBalance + amount : polymarketBalance - amount;
        } else {
            opinionBalance = add ? opinionBalance + amount : opinionBalance - amount;
        }
    }

    function _getBalance(Side side) internal view returns (uint256) {
        return side == Side.POLYMARKET ? polymarketBalance : opinionBalance;
    }

    function _oppositeSide(Side side) internal pure returns (Side) {
        return side == Side.POLYMARKET ? Side.OPINION : Side.POLYMARKET;
    }

    function _lpToken(Side side) internal view returns (LPToken) {
        return side == Side.POLYMARKET ? polyLpToken : opinionLpToken;
    }

    function _tokenAddress(Side side) internal view returns (address) {
        return side == Side.POLYMARKET ? factory.polymarketToken() : factory.opinionToken();
    }

    function _tokenId(Side side) internal view returns (uint256) {
        return side == Side.POLYMARKET ? polymarketTokenId : opinionTokenId;
    }
}