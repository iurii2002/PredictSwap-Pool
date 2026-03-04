// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";

/**
 * @title FeeCollector
 * @notice Accumulates the protocol's 0.10% fee cut from all SwapPool swaps.
 *         Fees are held as raw ERC-1155 shares (both Polymarket and WrappedOpinion).
 *         Only the owner (team) can withdraw.
 *
 *         Any registered SwapPool can push fees in; only owner can pull out.
 */
contract FeeCollector is Ownable, ERC1155Holder {
    // Pools authorised to deposit fees
    mapping(address => bool) public authorisedPools;

    event FeeReceived(
        address indexed pool,
        address indexed token,
        uint256 tokenId,
        uint256 amount
    );
    event FeeWithdrawn(
        address indexed token,
        uint256 tokenId,
        uint256 amount,
        address to
    );
    event PoolAuthorised(address indexed pool);
    event PoolRevoked(address indexed pool);

    error NotAuthorisedPool();
    error ZeroAmount();

    constructor(address owner_) Ownable(owner_) {}

    modifier onlyPool() {
        if (!authorisedPools[msg.sender]) revert NotAuthorisedPool();
        _;
    }

    // ─── Admin ────────────────────────────────────────────────────────────────

    function authorisePool(address pool) external onlyOwner {
        authorisedPools[pool] = true;
        emit PoolAuthorised(pool);
    }

    function revokePool(address pool) external onlyOwner {
        authorisedPools[pool] = false;
        emit PoolRevoked(pool);
    }

    // ─── Fee receipt (called by SwapPool during swap) ─────────────────────────

    /**
     * @notice Called by SwapPool to transfer protocol fee shares here.
     *         The pool must have already done safeTransferFrom before calling,
     *         OR this contract is the direct recipient in the pool's transfer.
     *         This function just emits the accounting event.
     */
    function recordFee(
        address token,
        uint256 tokenId,
        uint256 amount
    ) external onlyPool {
        if (amount == 0) revert ZeroAmount();
        emit FeeReceived(msg.sender, token, tokenId, amount);
    }

    // ─── Withdrawal (team only) ───────────────────────────────────────────────

    function withdraw(
        address token,
        uint256 tokenId,
        uint256 amount,
        address to
    ) external onlyOwner {
        if (amount == 0) revert ZeroAmount();
        IERC1155(token).safeTransferFrom(address(this), to, tokenId, amount, "");
        emit FeeWithdrawn(token, tokenId, amount, to);
    }

    function withdrawBatch(
        address token,
        uint256[] calldata tokenIds,
        uint256[] calldata amounts,
        address to
    ) external onlyOwner {
        IERC1155(token).safeBatchTransferFrom(address(this), to, tokenIds, amounts, "");
    }
}
