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

    error ZeroAmount();
    error ZeroAddress();

    constructor(address owner_) Ownable(owner_) {}
    
    // ─── Fee receipt (called by SwapPool during swap) ─────────────────────────

    /**
     * @notice Called by SwapPool to transfer protocol fee shares here.
     *         The pool must have already done safeTransferFrom before calling,
     *         OR this contract is the direct recipient in the pool's transfer.
     *         This function just emits the accounting event.
     *
     *          NOTE. Anyone can call this function and emit event. 
     *          To use this event correctly filter by msg.sender == SwapPool
     */
    function recordFee(
        address token,
        uint256 tokenId,
        uint256 amount
    ) external {
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
        if (to == address(0)) revert ZeroAddress();
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
        if (to == address(0)) revert ZeroAddress();
        for (uint256 i; i < tokenIds.length; i++) {
            if (amounts[i] == 0) revert ZeroAmount();
            emit FeeWithdrawn(token, tokenIds[i], amounts[i], to);
        }
        IERC1155(token).safeBatchTransferFrom(address(this), to, tokenIds, amounts, "");
    }

        /// @notice Withdraw the entire balance of a single token ID
    function withdrawAll(
        address token,
        uint256 tokenId,
        address to
    ) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        uint256 amount = IERC1155(token).balanceOf(address(this), tokenId);
        if (amount == 0) revert ZeroAmount();
        IERC1155(token).safeTransferFrom(address(this), to, tokenId, amount, "");
        emit FeeWithdrawn(token, tokenId, amount, to);
    }

    /// @notice Withdraw the entire balance of multiple token IDs in one call
    function withdrawAllBatch(
        address token,
        uint256[] calldata tokenIds,
        address to
    ) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        uint256[] memory amounts = new uint256[](tokenIds.length);
        for (uint256 i; i < tokenIds.length; i++) {
            amounts[i] = IERC1155(token).balanceOf(address(this), tokenIds[i]);
            emit FeeWithdrawn(token, tokenIds[i], amounts[i], to);
        }
        IERC1155(token).safeBatchTransferFrom(address(this), to, tokenIds, amounts, "");
    }
}
