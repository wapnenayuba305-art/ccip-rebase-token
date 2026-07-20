// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title RebaseToken
 * @author WAPNEN AYUBA WUBAL
 * @notice A cross-chain rebase token that incentivises users to deposit into a vault and gain interest in rewards.
 * @notice The interest rate can only decrease over time.
 * @notice Each user locks in the global interest rate at the time of their deposit.
*/
contract RebaseToken is ERC20, Ownable, AccessControl {

    error RebaseToken__InterestRateCanOnlyDecrease(uint256 oldInterestRate, uint256 newInterestRate);

    bytes32 public constant MINT_AND_BURN_ROLE = keccak256("MINT_AND_BURN_ROLE");

    uint256 private constant PRECISION_FACTOR = 1e18;
    uint256 private sInterestRate = 5e10;

    mapping(address => uint256) private sUserInterestRate;
    mapping(address => uint256) private sUserLastUpdatedTimestamp;

    event InterestRateSet(uint256 newInterestRate);

    constructor() ERC20("Rebase Token", "RBT") Ownable(msg.sender) {}

    // ─────────────────────────────────────────────
    // Admin
    // ─────────────────────────────────────────────

    /**
     * @notice Set the global interest rate. Can only decrease.
     * @param _newInterestRate New interest rate scaled by PRECISION_FACTOR per second.
     */
    function setInterestRate(uint256 _newInterestRate) external onlyOwner {
        if (_newInterestRate > sInterestRate) {
            revert RebaseToken__InterestRateCanOnlyDecrease(sInterestRate, _newInterestRate);
        }
        sInterestRate = _newInterestRate;
        emit InterestRateSet(_newInterestRate);
    }

    /**
     * @notice Grant the MINT_AND_BURN_ROLE to an account (e.g. the Vault).
     * @param _account The address to grant the role to.
     */
    function grantMintAndBurnRole(address _account) external onlyOwner {
        _grantRole(MINT_AND_BURN_ROLE, _account);
    }

    // ─────────────────────────────────────────────
    // Mint & Burn
    // ─────────────────────────────────────────────

    /**
     * @notice Mints tokens to a user, typically upon vault deposit or cross-chain bridging.
     * @dev Mints any accrued interest first, then sets the user's rate explicitly, then mints principal.
     * @param _to The address to mint tokens to.
     * @param _amount The principal amount of tokens to mint.
     * @param _userInterestRate The interest rate to assign to this user (e.g. propagated cross-chain, or the current global rate for new local deposits).
    */
    function mint(address _to, uint256 _amount, uint256 _userInterestRate) external onlyRole(MINT_AND_BURN_ROLE) {
        // 1. Settle any accrued interest before changing principal
        _mintAccruedInterest(_to);

        // 2. Set the user's interest rate to the one explicitly provided
        sUserInterestRate[_to] = _userInterestRate;

        // 3. Mint the deposited principal
        _mint(_to, _amount);
    }

    /**
     * @notice Burns tokens from a user, typically upon vault redemption.
     * @dev Mints any accrued interest first so super.balanceOf reflects the full balance before burning.
     * @param _from The address to burn tokens from.
     * @param _amount The amount of tokens to burn. Pass type(uint256).max to burn entire balance.
     */
    function burn(address _from, uint256 _amount) external onlyRole(MINT_AND_BURN_ROLE) {
        // 1. Settle accrued interest — this updates super.balanceOf to the full current balance
        _mintAccruedInterest(_from);

        // 2. If burning max, resolve to the full balance
        if (_amount == type(uint256).max) {
            _amount = super.balanceOf(_from);
        }

        // 3. Burn the resolved amount
        _burn(_from, _amount);
    }

    // ─────────────────────────────────────────────
    // Balance & Interest
    // ─────────────────────────────────────────────

    /**
     * @notice Returns the current balance of an account, including accrued interest.
     * @param _user The address of the account.
     * @return The total balance including interest.
     */
    function balanceOf(address _user) public view override returns (uint256) {
        // Multiply principal by the growth factor (interest accumulation since last update)
        // ✅ Fixed: was incorrectly adding interest/precision instead of multiplying
        return super.balanceOf(_user) * _calculateUserAccumulatedInterestSinceLastUpdate(_user) / PRECISION_FACTOR;
    }

    /**
     * @dev Calculates accumulated interest growth factor since the user's last update.
     * @param _user The address of the user.
     * @return linearInterestFactor Growth factor scaled by PRECISION_FACTOR (e.g. 1.05x = 1.05e18).
     */
    function _calculateUserAccumulatedInterestSinceLastUpdate(address _user) internal view returns (uint256 linearInterestFactor) {
        uint256 timeElapsed = block.timestamp - sUserLastUpdatedTimestamp[_user];

        if (timeElapsed == 0 || sUserInterestRate[_user] == 0) {
            return PRECISION_FACTOR;
        }

        uint256 fractionalInterest = sUserInterestRate[_user] * timeElapsed;
        linearInterestFactor = PRECISION_FACTOR + fractionalInterest;
        return linearInterestFactor;
    }

    /**
     * @dev Calculates and mints accrued interest for a user, then snapshots the timestamp.
     * @param _user The address of the user.
     */
    function _mintAccruedInterest(address _user) internal {
        uint256 previousPrincipalBalance = super.balanceOf(_user);
        uint256 currentBalance = balanceOf(_user);
        uint256 balanceIncrease = currentBalance - previousPrincipalBalance;

        // Snapshot timestamp before minting (effects before interactions)
        sUserLastUpdatedTimestamp[_user] = block.timestamp;

        if (balanceIncrease > 0) {
            _mint(_user, balanceIncrease);
        }
    }

    // ─────────────────────────────────────────────
    // Transfers
    // ─────────────────────────────────────────────

    /**
     * @notice Transfers tokens from the caller to a recipient.
     * @dev Accrued interest for both parties is minted first. New recipients inherit the sender's rate.
     * @param _recipient The address to transfer tokens to.
     * @param _amount The amount to transfer. Pass type(uint256).max to transfer full balance.
     * @return True if the transfer succeeded.
     */
    function transfer(address _recipient, uint256 _amount) public override returns (bool) {
        _mintAccruedInterest(msg.sender);
        _mintAccruedInterest(_recipient);

        if (_amount == type(uint256).max) {
            _amount = balanceOf(msg.sender);
        }

        if (balanceOf(_recipient) == 0 && _amount > 0) {
            sUserInterestRate[_recipient] = sUserInterestRate[msg.sender];
        }

        return super.transfer(_recipient, _amount);
    }

    /**
     * @notice Transfers tokens from one address to another on behalf of the sender.
     * @dev Accrued interest for both parties is minted first. New recipients inherit the sender's rate.
     * @param _sender The address to transfer tokens from.
     * @param _recipient The address to transfer tokens to.
     * @param _amount The amount to transfer. Pass type(uint256).max to transfer full balance.
     * @return True if the transfer succeeded.
     */
    function transferFrom(address _sender, address _recipient, uint256 _amount) public override returns (bool) {
        _mintAccruedInterest(_sender);
        _mintAccruedInterest(_recipient);

        if (_amount == type(uint256).max) {
            _amount = balanceOf(_sender);
        }

        if (balanceOf(_recipient) == 0 && _amount > 0) {
            sUserInterestRate[_recipient] = sUserInterestRate[_sender];
        }

        return super.transferFrom(_sender, _recipient, _amount);
    }

    // ─────────────────────────────────────────────
    // View Helpers
    // ─────────────────────────────────────────────

    /**
     * @notice Returns the principal balance of a user (excludes accrued interest).
     * @param _user The address of the user.
     * @return The principal balance.
     */
    function principleBalanceOf(address _user) external view returns (uint256) {
        return super.balanceOf(_user);
    }

    /**
     * @notice Returns the locked-in interest rate for a specific user.
     * @param _user The address of the user.
     * @return The user's interest rate.
     */
    function getUserInterestRate(address _user) external view returns (uint256) {
        return sUserInterestRate[_user];
    }

    /**
     * @notice Returns the current global interest rate.
     * @return The current interest rate.
     */
    function getInterestRate() external view returns (uint256) {
        return sInterestRate;
    }
}