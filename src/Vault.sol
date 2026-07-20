// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {IRebaseToken} from "./interfaces/IRebaseToken.sol";

/// @title Vault
/// @author wapnen ayuba wubal
/// @notice A vault contract that accepts ETH deposits and mints RebaseTokens in return.
/// @dev Interacts with a RebaseToken contract via the IRebaseToken interface.
///      ETH rewards can be sent directly to this contract via the receive() fallback.
contract Vault {

    /// @dev The RebaseToken contract this vault interacts with.
    ///      Set once at deployment and cannot be changed (immutable).
    IRebaseToken private immutable I_REBASE_TOKEN;

    /// @notice Emitted when a user deposits ETH and receives RebaseTokens.
    /// @param user The address of the depositing user.
    /// @param amount The amount of ETH deposited (and tokens minted), in wei.
    event Deposit(address indexed user, uint256 amount);

    /// @notice Emitted when a user redeems RebaseTokens for ETH.
    /// @param user The address of the redeeming user.
    /// @param amount The amount of tokens burned (and ETH returned), in wei.
    event Redeem(address indexed user, uint256 amount);

    /// @notice Thrown when the ETH transfer to the user fails during redemption.
    error Vault_RedeemFailed();

    /// @notice Thrown when a deposit is attempted with zero ETH.
    error Vault_DepositAmountIsZero();

    /// @notice Initialises the vault with the address of the RebaseToken contract.
    /// @param _rebaseToken The address of the deployed RebaseToken contract,
    ///        accessed via the IRebaseToken interface.
    constructor(IRebaseToken _rebaseToken) {
        I_REBASE_TOKEN = _rebaseToken;
    }

    /// @notice Accepts ETH sent directly to this contract (e.g. rewards).
    /// @dev Any ETH transferred to this contract without calldata will be accepted.
    ///      This allows external parties to top up the vault with ETH rewards.
    receive() external payable {}

    /// @notice Allows a user to deposit ETH and receive an equivalent amount of RebaseTokens.
    /// @dev Mints RebaseTokens 1:1 with the ETH sent (msg.value).
    ///      Reverts if no ETH is sent.
    function deposit() external payable {
        uint256 amountToMint = msg.value;

        if (amountToMint == 0) {
            revert Vault_DepositAmountIsZero();
        }

        I_REBASE_TOKEN.mint(
            msg.sender,
            amountToMint,
            I_REBASE_TOKEN.getInterestRate()
        );

        emit Deposit(msg.sender, amountToMint);
    }

    /// @notice Allows a user to burn RebaseTokens and receive an equivalent amount of ETH.
    /// @dev Burns `_amount` of RebaseTokens from the caller, then transfers
    ///      the equivalent ETH back to the caller using a low-level call.
    ///      Reverts with `Vault_RedeemFailed` if the ETH transfer fails.
    /// @param _amount The amount of RebaseTokens to burn and ETH to receive, in wei.
    function redeem(uint256 _amount) external {
        I_REBASE_TOKEN.burn(msg.sender, _amount);

        (bool success, ) = payable(msg.sender).call{value: _amount}("");
        if (!success) {
            revert Vault_RedeemFailed();
        }

        emit Redeem(msg.sender, _amount);
    }

    /// @notice Returns the address of the RebaseToken contract linked to this vault.
    /// @return The address of the IRebaseToken contract.
    function getRebaseTokenAddress() external view returns (address) {
        return address(I_REBASE_TOKEN);
    }
}