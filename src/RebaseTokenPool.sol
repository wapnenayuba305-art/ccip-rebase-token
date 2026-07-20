// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TokenPool} from "@ccip/contracts/pools/TokenPool.sol";
import {IERC20} from "@openzeppelin/contracts@5.3.0/token/ERC20/IERC20.sol";
import {IRebaseToken} from "./interfaces/IRebaseToken.sol";
import {Pool} from "@ccip/contracts/libraries/Pool.sol";

contract RebaseTokenPool is TokenPool {
    constructor(
        IERC20 _token,
        address _rnmProxy,
        address _router
    ) TokenPool(
        _token,
        18,
        address(0),
        _rnmProxy,
        _router
    ) {}

    function lockOrBurn(
        Pool.LockOrBurnInV1 calldata lockOrBurnIn
    ) public override returns (Pool.LockOrBurnOutV1 memory lockOrBurnOut) {
        _validateLockOrBurn(
            lockOrBurnIn,
            bytes4(0),
            "",
            0
        );

        // Decode the original sender's address
        address originalSender = lockOrBurnIn.originalSender;

        // Fetch the user's current interest rate from the rebase token
        uint256 userInterestRate = IRebaseToken(address(i_token)).getUserInterestRate(originalSender);

        // Burn the specified amount of tokens from this pool contract
        // CCIP transfers tokens to the pool before lockOrBurn is called
        IRebaseToken(address(i_token)).burn(address(this), lockOrBurnIn.amount);

        // Prepare the output data for CCIP
        lockOrBurnOut = Pool.LockOrBurnOutV1({
            destTokenAddress: getRemoteToken(lockOrBurnIn.remoteChainSelector),
            destPoolData: abi.encode(userInterestRate) // Encode the interest rate to send cross-chain
        });
    }

    function releaseOrMint(
        Pool.ReleaseOrMintInV1 calldata releaseOrMintIn
    ) public override returns (Pool.ReleaseOrMintOutV1 memory) {
        _validateReleaseOrMint(
            releaseOrMintIn,
            releaseOrMintIn.sourceDenominatedAmount,
            bytes4(0)
        );

        // Decode the user interest rate sent from the source pool
        uint256 userInterestRate = abi.decode(releaseOrMintIn.sourcePoolData, (uint256));

        // The receiver address is directly available
        address receiver = releaseOrMintIn.receiver;

        // Mint tokens to the receiver, applying the propagated interest rate
        IRebaseToken(address(i_token)).mint(
            receiver,
            releaseOrMintIn.sourceDenominatedAmount,
            userInterestRate
        );

        return Pool.ReleaseOrMintOutV1({
            destinationAmount: releaseOrMintIn.sourceDenominatedAmount
        });
    }
}