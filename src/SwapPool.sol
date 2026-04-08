// SPDX-License-Identifier: BUSL-1.1
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
 * @notice Holds two ERC-1155 prediction market shares for ONE specific event-outcome
 *         pair (marketA and marketB). Both sides represent the same real-world outcome
 *         and are treated as 1:1 equivalent in value.
 *
 *         Fully self-describing — stores all identifying information about both markets
 *         including contract addresses, token IDs, decimals, platform names, and fees.
 *         No factory lookup needed to understand what a pool represents or what it charges.
 *
 *         Deployed by PoolFactory. One pool per matched market pair.
 *
 * ─── Two LP tokens ────────────────────────────────────────────────────────────
 *
 *   marketALpToken — minted when depositing marketA shares
 *   marketBLpToken — minted when depositing marketB shares
 *
 *   Both LP tokens share a single unified exchange rate:
 *     rate = totalSharesNorm() / totalLpSupply()
 *
 *   The LP token type records which side a user deposited from, which
 *   determines same-side vs cross-side withdrawal rules. It does NOT
 *   affect the exchange rate — all LP holders earn fees equally.
 *
 * ─── Decimal normalization ────────────────────────────────────────────────────
 *
 *   Raw balances are stored in each token's native decimals.
 *   All pool math (LP minting, exchange rate, fee computation) operates in a
 *   shared 18-decimal normalized space. Transfers always use raw amounts.
 *
 *   _toNorm(side, raw)    → normalized (18 dec)
 *   _fromNorm(side, norm) → raw (native dec)
 *
 * ─── Pool Mechanics ───────────────────────────────────────────────────────────
 *
 *   totalLpSupply  = marketALpToken.totalSupply() + marketBLpToken.totalSupply()
 *   rate           = totalSharesNorm() / totalLpSupply()
 *   lpToMint       = normAmount * totalLpSupply / totalSharesNorm  (or 1:1 if first)
 *   normOut        = lpBurned * totalSharesNorm / totalLpSupply
 *   rawOut         = _fromNorm(receiveSide, normOut)
 *
 * ─── Withdrawal rules ─────────────────────────────────────────────────────────
 *
 *   Same-side  (burn marketALp → receive marketA, or marketBLp → marketB):
 *     Free, instant, no fee.
 *
 *   Cross-side (burn marketALp → receive marketB, or vice versa):
 *     Swap fee applies (LP fee + protocol fee), same as swap().
 *     After pool is marked resolved: cross-side is also free (market settled).
 *
 * ─── Swap fee ─────────────────────────────────────────────────────────────────
 *
 *   Set at pool creation, adjustable by owner via factory.setPoolFees().
 *     LP fee       → stays in pool on fromSide (auto-compounds for LPs)
 *     Protocol fee → transferred to FeeCollector
 *
 * ─── Access control ───────────────────────────────────────────────────────────
 *
 *   All admin functions are callable only by the factory contract. The factory
 *   enforces its own role split before routing calls here:
 *
 *   Factory owner only:
 *     setFees, rescueTokens, rescueERC1155, rescueERC20, rescueETH
 *
 *   Factory operator (or owner):
 *     setDepositsPaused, setSwapsPaused,
 *     setResolvedAndPausedDeposits, unsetResolved
 */
contract SwapPool is ERC1155Holder, ReentrancyGuard {

    using SafeERC20 for IERC20;

    // ─── Constants ────────────────────────────────────────────────────────────

    uint256 private constant RATE_PRECISION   = 1e18;
    uint256 public  constant FEE_DENOMINATOR  = 10_000;
    uint256 public  constant MAX_LP_FEE       = 100; // 1.00% hard cap
    uint256 public  constant MAX_PROTOCOL_FEE = 50;  // 0.50% hard cap

    // ─── Immutable config ─────────────────────────────────────────────────────

    /// @notice Factory that deployed this pool — sole authorized caller of admin functions.
    PoolFactory public immutable factory;

    // Market A — hot path immutables
    address public immutable marketAContract;  // ERC-1155 prediction market contract
    uint256 public immutable marketATokenId;   // outcome/event ID within that contract
    uint8   public immutable marketADecimals;

    // Market B — hot path immutables
    address public immutable marketBContract;
    uint256 public immutable marketBTokenId;
    uint8   public immutable marketBDecimals;

    /// @notice LP token for marketA depositors
    LPToken public immutable marketALpToken;
    /// @notice LP token for marketB depositors
    LPToken public immutable marketBLpToken;

    /// @notice Protocol fee recipient
    FeeCollector public immutable feeCollector;

    // ─── Fee config (mutable, owner-gated via factory) ────────────────────────

    /// @notice LP fee in basis points — stays in pool, auto-compounds for LPs.
    ///         Adjustable by factory owner via factory.setPoolFees().
    uint256 public lpFeeBps;

    /// @notice Protocol fee in basis points — sent to FeeCollector.
    ///         Adjustable by factory owner via factory.setPoolFees().
    uint256 public protocolFeeBps;

    // ─── Cold metadata (UI only, never read in hot path) ──────────────────────

    /// @notice Human-readable platform name, e.g. "Polymarket"
    string public marketAName;
    /// @notice Human-readable platform name, e.g. "Opinion"
    string public marketBName;

    // ─── Pool state ───────────────────────────────────────────────────────────

    /// @notice Raw marketA shares held in this pool (native decimals)
    uint256 public marketABalance;
    /// @notice Raw marketB shares held in this pool (native decimals)
    uint256 public marketBBalance;

    bool public resolved;
    bool public depositsPaused;
    bool public swapsPaused;

    // ─── Types ────────────────────────────────────────────────────────────────

    enum Side {
        MARKET_A,
        MARKET_B
    }

    // ─── Events ───────────────────────────────────────────────────────────────

    event DepositsPausedSet(bool isPaused);
    event SwapsPausedSet(bool isPaused);
    event Resolved(bool isResolved);
    event FeesUpdated(uint256 lpFeeBps, uint256 protocolFeeBps);

    event Deposited(address indexed user, Side side, uint256 sharesIn, uint256 lpMinted);

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
    event ERC1155Rescued(address indexed marketContract, uint256 tokenId, uint256 amount, address indexed to);
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
    error InvalidDecimals();
    error FeeTooHigh();
    error DepositTooSmall();
    error Unauthorized();
    error NothingToRescue();
    error CannotRescuePoolTokens();
    error InsufficientLiquidity(uint256 available, uint256 required);

    // ─── Constructor ──────────────────────────────────────────────────────────

    constructor(
        address factory_,
        PoolFactory.MarketConfig memory marketA_,
        PoolFactory.MarketConfig memory marketB_,
        uint256 lpFeeBps_,
        uint256 protocolFeeBps_,
        address marketALpToken_,
        address marketBLpToken_,
        address feeCollector_
    ) {
        if (
            factory_         == address(0) ||
            marketALpToken_  == address(0) ||
            marketBLpToken_  == address(0) ||
            feeCollector_    == address(0)
        ) revert ZeroAddress();

        if (marketA_.marketContract == address(0) || marketB_.marketContract == address(0))
            revert ZeroAddress();
        if (marketA_.tokenId == 0 || marketB_.tokenId == 0) revert InvalidTokenID();
        if (marketA_.decimals > 18 || marketB_.decimals > 18) revert InvalidDecimals();
        if (lpFeeBps_ > MAX_LP_FEE) revert FeeTooHigh();
        if (protocolFeeBps_ > MAX_PROTOCOL_FEE) revert FeeTooHigh();

        factory = PoolFactory(factory_);

        // Hot-path immutables
        marketAContract = marketA_.marketContract;
        marketATokenId  = marketA_.tokenId;
        marketADecimals = marketA_.decimals;

        marketBContract = marketB_.marketContract;
        marketBTokenId  = marketB_.tokenId;
        marketBDecimals = marketB_.decimals;

        lpFeeBps       = lpFeeBps_;
        protocolFeeBps = protocolFeeBps_;

        marketALpToken = LPToken(marketALpToken_);
        marketBLpToken = LPToken(marketBLpToken_);
        feeCollector   = FeeCollector(feeCollector_);

        // Cold metadata — written once at deploy, never read by swap/deposit/withdraw
        marketAName = marketA_.name;
        marketBName = marketB_.name;
    }

    // ─── View helpers ─────────────────────────────────────────────────────────

    /// @notice Total shares across both sides, normalized to 18 decimals.
    function totalSharesNorm() public view returns (uint256) {
        return _toNorm(Side.MARKET_A, marketABalance)
             + _toNorm(Side.MARKET_B, marketBBalance);
    }

    /// @notice Combined supply of both LP tokens — unified denominator.
    function totalLpSupply() public view returns (uint256) {
        return marketALpToken.totalSupply() + marketBLpToken.totalSupply();
    }

    /// @notice Total fee in basis points (LP + protocol).
    function totalFeeBps() public view returns (uint256) {
        return lpFeeBps + protocolFeeBps;
    }

    /**
     * @notice Current LP exchange rate scaled by 1e18.
     *         Returns 1e18 when pool is empty (first deposit rate).
     */
    function exchangeRate() public view returns (uint256) {
        uint256 supply = totalLpSupply();
        if (supply == 0) return RATE_PRECISION;
        return (totalSharesNorm() * RATE_PRECISION) / supply;
    }

    // ─── Fee helper ───────────────────────────────────────────────────────────

    /**
     * @notice Compute LP fee and protocol fee on a normalized amount.
     *         Ceiling division ensures any non-zero amount with non-zero bps
     *         pays at least 1 unit of fee, preventing fee evasion via splitting.
     *
     * @param normAmount   Gross normalized (18 dec) amount subject to fees
     * @return lpFee       Normalized fee retained by the pool (auto-compounds)
     * @return protocolFee Normalized fee transferred to FeeCollector
     */
    function _computeFees(uint256 normAmount) internal view returns (uint256 lpFee, uint256 protocolFee) {
        uint256 totalBps = lpFeeBps + protocolFeeBps;
        if (totalBps == 0) return (0, 0);

        // Single ceiling rounding on the combined fee — one rounding event
        uint256 totalFee = (normAmount * totalBps + FEE_DENOMINATOR - 1) / FEE_DENOMINATOR;

        // Split proportionally: protocolFee gets floor, lpFee absorbs the remainder
        protocolFee = protocolFeeBps > 0 ? (totalFee * protocolFeeBps) / totalBps : 0;
        lpFee       = totalFee - protocolFee;
    }

    // ─── Deposit ──────────────────────────────────────────────────────────────

    /**
     * @notice Deposit shares into the pool and receive the matching LP token.
     *         Depositing marketA shares mints marketALpToken.
     *         Depositing marketB shares mints marketBLpToken.
     *
     * @param side    Which market to deposit (MARKET_A or MARKET_B)
     * @param amount  Raw number of ERC-1155 shares to deposit (native decimals)
     */
    function deposit(Side side, uint256 amount) external nonReentrant returns (uint256 lpMinted) {
        if (depositsPaused) revert DepositsPaused();
        if (amount == 0) revert ZeroAmount();

        _pullTokens(side, msg.sender, amount);

        uint256 normAmount = _toNorm(side, amount);
        uint256 supply     = totalLpSupply();

        if (supply == 0) {
            lpMinted = normAmount;
        } else {
            lpMinted = (normAmount * supply) / totalSharesNorm();
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
     *         Same-side   (lpSide == receiveSide): free, no fee.
     *         Cross-side  (lpSide != receiveSide): swap fee deducted from output,
     *                     unless the pool is marked resolved.
     *
     * @param lpAmount     LP tokens to burn
     * @param lpSide       Side of LP token to burn
     * @param receiveSide  Side of ERC-1155 shares to receive
     */
    function withdrawSingleSide(
        uint256 lpAmount,
        Side lpSide,
        Side receiveSide
    ) external nonReentrant returns (uint256 sharesReceived) {
        if (lpAmount == 0) revert ZeroAmount();

        uint256 normOut = (lpAmount * totalSharesNorm()) / totalLpSupply();

        _lpToken(lpSide).burn(msg.sender, lpAmount);

        uint256 lpFee;
        uint256 protocolFee;

        if (lpSide == receiveSide) {
            // ── Same-side: free ──────────────────────────────────────────────
            uint256 rawOut = _fromNorm(receiveSide, normOut);
            uint256 avail  = _getBalance(receiveSide);
            if (rawOut > avail) revert InsufficientLiquidity(avail, rawOut);

            _updateBalance(receiveSide, rawOut, false);
            _pushTokens(receiveSide, msg.sender, rawOut);

            sharesReceived = rawOut;
            _flushResidualIfEmpty();
            emit WithdrawnSingleSide(msg.sender, lpSide, receiveSide, lpAmount, rawOut, 0, 0);

        } else {
            // ── Cross-side ───────────────────────────────────────────────────
            if (swapsPaused) revert SwapsPaused();

            uint256 rawActual;

            if (resolved) {
                rawActual     = _fromNorm(receiveSide, normOut);
                uint256 avail = _getBalance(receiveSide);
                if (rawActual > avail) revert InsufficientLiquidity(avail, rawActual);
                _updateBalance(receiveSide, rawActual, false);
                _pushTokens(receiveSide, msg.sender, rawActual);
            } else {
                (lpFee, protocolFee)    = _computeFees(normOut);
                uint256 normActual      = normOut - lpFee - protocolFee;
                rawActual               = _fromNorm(receiveSide, normActual);
                uint256 rawProtocol     = _fromNorm(receiveSide, protocolFee);

                uint256 avail = _getBalance(receiveSide);
                if (rawActual + rawProtocol > avail) revert InsufficientLiquidity(avail, rawActual + rawProtocol);

                _updateBalance(receiveSide, rawActual + rawProtocol, false);
                _pushTokens(receiveSide, msg.sender, rawActual);

                if (rawProtocol > 0) {
                    _pushTokens(receiveSide, address(feeCollector), rawProtocol);
                    feeCollector.recordFee(_marketContract(receiveSide), _tokenId(receiveSide), rawProtocol);
                }
            }

            sharesReceived = rawActual;
            _flushResidualIfEmpty();
            emit WithdrawnSingleSide(msg.sender, lpSide, receiveSide, lpAmount, rawActual, lpFee, protocolFee);
        }
    }

    /**
     * @notice Burn LP tokens and receive a split of same-side and cross-side shares.
     *
     * @param lpAmount      LP tokens to burn
     * @param lpSide        Side of LP token to burn
     * @param samesideBps   Fraction of gross output as same-side (e.g. 5000 = 50%)
     */
    function withdrawBothSides(
        uint256 lpAmount,
        Side lpSide,
        uint256 samesideBps
    ) external nonReentrant returns (uint256 samesideReceived, uint256 crosssideReceived) {
        if (lpAmount == 0) revert ZeroAmount();
        if (samesideBps > FEE_DENOMINATOR) revert InvalidSplit();

        uint256 normGross     = (lpAmount * totalSharesNorm()) / totalLpSupply();
        uint256 normSameside  = (normGross * samesideBps) / FEE_DENOMINATOR;
        uint256 normCrossside = normGross - normSameside;

        _lpToken(lpSide).burn(msg.sender, lpAmount);

        Side sameSide  = lpSide;
        Side crossSide = _oppositeSide(lpSide);

        // Same-side: free
        if (normSameside > 0) {
            uint256 rawSame = _fromNorm(sameSide, normSameside);
            uint256 avail   = _getBalance(sameSide);
            if (rawSame > avail) revert InsufficientLiquidity(avail, rawSame);
            _updateBalance(sameSide, rawSame, false);
            _pushTokens(sameSide, msg.sender, rawSame);
            samesideReceived = rawSame;
        }

        uint256 crossLpFee;
        uint256 crossProtocolFee;
        uint256 crossRawActual;

        if (normCrossside > 0) {
            if (swapsPaused) revert SwapsPaused();
            uint256 avail = _getBalance(crossSide);

            if (resolved) {
                crossRawActual = _fromNorm(crossSide, normCrossside);
                if (crossRawActual > avail) revert InsufficientLiquidity(avail, crossRawActual);
                _updateBalance(crossSide, crossRawActual, false);
                _pushTokens(crossSide, msg.sender, crossRawActual);
            } else {
                (crossLpFee, crossProtocolFee) = _computeFees(normCrossside);
                uint256 normCrossActual   = normCrossside - crossLpFee - crossProtocolFee;
                crossRawActual            = _fromNorm(crossSide, normCrossActual);
                uint256 crossRawProtocol  = _fromNorm(crossSide, crossProtocolFee);

                if (crossRawActual + crossRawProtocol > avail)
                    revert InsufficientLiquidity(avail, crossRawActual + crossRawProtocol);

                _updateBalance(crossSide, crossRawActual + crossRawProtocol, false);
                _pushTokens(crossSide, msg.sender, crossRawActual);

                if (crossRawProtocol > 0) {
                    _pushTokens(crossSide, address(feeCollector), crossRawProtocol);
                    feeCollector.recordFee(_marketContract(crossSide), _tokenId(crossSide), crossRawProtocol);
                }
            }
        }

        crosssideReceived = crossRawActual;
        _flushResidualIfEmpty();
        emit WithdrawnBothSides(msg.sender, lpSide, lpAmount, samesideReceived, crossRawActual, crossLpFee, crossProtocolFee);
    }

    /// @dev Flush any residual balance to feeCollector when the last LP exits.
    ///      Prevents first-depositor capture of orphaned LP fees.
    function _flushResidualIfEmpty() internal {
        if (totalLpSupply() > 0) return;

        if (marketABalance > 0) {
            uint256 amount = marketABalance;
            marketABalance = 0;
            _pushTokens(Side.MARKET_A, address(feeCollector), amount);
            feeCollector.recordFee(marketAContract, marketATokenId, amount);
        }
        if (marketBBalance > 0) {
            uint256 amount = marketBBalance;
            marketBBalance = 0;
            _pushTokens(Side.MARKET_B, address(feeCollector), amount);
            feeCollector.recordFee(marketBContract, marketBTokenId, amount);
        }
    }

    // ─── Swap ─────────────────────────────────────────────────────────────────

    /**
     * @notice Swap shares from one market to the other at 1:1 minus fee.
     *         Normalization ensures correct exchange across different decimals.
     *
     * @param fromSide  Side being deposited
     * @param sharesIn  Raw shares deposited (native decimals of fromSide)
     */
    function swap(Side fromSide, uint256 sharesIn) external nonReentrant returns (uint256 sharesOut) {
        if (swapsPaused) revert SwapsPaused();
        if (sharesIn == 0) revert ZeroAmount();

        Side toSide = _oppositeSide(fromSide);

        uint256 normIn = _toNorm(fromSide, sharesIn);
        (uint256 lpFee, uint256 protocolFee) = _computeFees(normIn);
        uint256 normOut = normIn - lpFee - protocolFee;

        sharesOut           = _fromNorm(toSide, normOut);
        uint256 rawProtocol = _fromNorm(fromSide, protocolFee);

        uint256 toBalance = _getBalance(toSide);
        if (sharesOut > toBalance) revert InsufficientLiquidity(toBalance, sharesOut);

        _pullTokens(fromSide, msg.sender, sharesIn);

        if (rawProtocol > 0) {
            _pushTokens(fromSide, address(feeCollector), rawProtocol);
            feeCollector.recordFee(_marketContract(fromSide), _tokenId(fromSide), rawProtocol);
        }

        _pushTokens(toSide, msg.sender, sharesOut);

        // LP fee stays in fromSide balance: add (sharesIn - rawProtocol)
        _updateBalance(fromSide, sharesIn - rawProtocol, true);
        _updateBalance(toSide, sharesOut, false);

        emit Swapped(msg.sender, fromSide, sharesIn, sharesOut, lpFee, protocolFee);
    }

    // ─── Admin ────────────────────────────────────────────────────────────────

    /// @notice Pause or unpause deposits. Called by factory. Operator or owner.
    function setDepositsPaused(bool paused_) external {
        if (msg.sender != address(factory)) revert Unauthorized();
        depositsPaused = paused_;
        emit DepositsPausedSet(paused_);
    }

    /// @notice Pause or unpause swaps. Called by factory. Operator or owner.
    function setSwapsPaused(bool paused_) external {
        if (msg.sender != address(factory)) revert Unauthorized();
        swapsPaused = paused_;
        emit SwapsPausedSet(paused_);
    }

    /// @notice Mark pool as resolved and pause deposits. Cross-side withdrawals become fee-free.
    ///         Call once the underlying prediction market event has settled.
    ///         Called by factory. Operator or owner.
    function setResolvedAndPausedDeposits() external {
        if (msg.sender != address(factory)) revert Unauthorized();
        if (resolved) revert AlreadyResolved();
        resolved = true;
        depositsPaused = true;
        emit Resolved(resolved);
        emit DepositsPausedSet(depositsPaused);
    }

    /// @notice Unmark pool as resolved. In case it was resolved by mistake.
    ///         Called by factory. Operator or owner.
    function unsetResolved() external {
        if (msg.sender != address(factory)) revert Unauthorized();
        if (!resolved) revert NotResolved();
        resolved = false;
        emit Resolved(resolved);
    }

    /// @notice Update LP and protocol fee rates. Capped by MAX_LP_FEE and MAX_PROTOCOL_FEE.
    ///         Called by factory. Owner only.
    function setFees(uint256 lpFeeBps_, uint256 protocolFeeBps_) external {
        if (msg.sender != address(factory)) revert Unauthorized();
        if (lpFeeBps_ > MAX_LP_FEE) revert FeeTooHigh();
        if (protocolFeeBps_ > MAX_PROTOCOL_FEE) revert FeeTooHigh();
        lpFeeBps       = lpFeeBps_;
        protocolFeeBps = protocolFeeBps_;
        emit FeesUpdated(lpFeeBps_, protocolFeeBps_);
    }

    // ─── Rescue ───────────────────────────────────────────────────────────────

    /// @notice Recover surplus pool tokens sent directly without using deposit().
    ///         Only the untracked surplus above the pool's accounting is rescuable.
    ///         LP holder funds are never at risk.
    ///         Called by factory. Owner only.
    function rescueTokens(Side side, uint256 amount, address to) external {
        if (msg.sender != address(factory)) revert Unauthorized();
        if (to == address(0)) revert ZeroAddress();

        uint256 tracked = _getBalance(side);
        uint256 actual  = IERC1155(_marketContract(side)).balanceOf(address(this), _tokenId(side));
        uint256 surplus = actual - tracked;
        if (amount > surplus) revert NothingToRescue();

        _pushTokens(side, to, amount);
        emit TokensRescued(side, amount, to);
    }

    /// @notice Recover any other ERC-1155 token accidentally sent to this contract.
    ///         Reverts if the contract address is either of the pool's own market contracts.
    ///         Called by factory. Owner only.
    function rescueERC1155(address contractAddress_, uint256 tokenId_, uint256 amount, address to) external {
        if (msg.sender != address(factory)) revert Unauthorized();
        if (to == address(0)) revert ZeroAddress();
        if (contractAddress_ == marketAContract || contractAddress_ == marketBContract)
            revert CannotRescuePoolTokens();
        IERC1155(contractAddress_).safeTransferFrom(address(this), to, tokenId_, amount, "");
        emit ERC1155Rescued(contractAddress_, tokenId_, amount, to);
    }

    /// @notice Recover any ERC-20 token accidentally sent to this contract.
    ///         Called by factory. Owner only.
    function rescueERC20(address token, uint256 amount, address to) external {
        if (msg.sender != address(factory)) revert Unauthorized();
        if (to == address(0)) revert ZeroAddress();
        IERC20(token).safeTransfer(to, amount);
        emit ERC20Rescued(token, amount, to);
    }

    /// @notice Recover ETH accidentally sent to this contract.
    ///         Called by factory. Owner only.
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

    function _toNorm(Side side, uint256 raw) internal view returns (uint256) {
        uint8 dec = side == Side.MARKET_A ? marketADecimals : marketBDecimals;
        if (dec == 18) return raw;
        return raw * 10 ** (18 - dec);
    }

    function _fromNorm(Side side, uint256 norm) internal view returns (uint256) {
        uint8 dec = side == Side.MARKET_A ? marketADecimals : marketBDecimals;
        if (dec == 18) return norm;
        return norm / 10 ** (18 - dec);
    }

    function _pullTokens(Side side, address from, uint256 amount) internal {
        IERC1155(_marketContract(side)).safeTransferFrom(from, address(this), _tokenId(side), amount, "");
    }

    function _pushTokens(Side side, address to, uint256 amount) internal {
        IERC1155(_marketContract(side)).safeTransferFrom(address(this), to, _tokenId(side), amount, "");
    }

    function _updateBalance(Side side, uint256 amount, bool add) internal {
        if (side == Side.MARKET_A) {
            marketABalance = add ? marketABalance + amount : marketABalance - amount;
        } else {
            marketBBalance = add ? marketBBalance + amount : marketBBalance - amount;
        }
    }

    function _getBalance(Side side) internal view returns (uint256) {
        return side == Side.MARKET_A ? marketABalance : marketBBalance;
    }

    function _oppositeSide(Side side) internal pure returns (Side) {
        return side == Side.MARKET_A ? Side.MARKET_B : Side.MARKET_A;
    }

    function _lpToken(Side side) internal view returns (LPToken) {
        return side == Side.MARKET_A ? marketALpToken : marketBLpToken;
    }

    function _marketContract(Side side) internal view returns (address) {
        return side == Side.MARKET_A ? marketAContract : marketBContract;
    }

    function _tokenId(Side side) internal view returns (uint256) {
        return side == Side.MARKET_A ? marketATokenId : marketBTokenId;
    }
}