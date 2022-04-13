/*
    Copyright 2022 JOJO Exchange
    SPDX-License-Identifier: Apache-2.0
*/

pragma solidity 0.8.9;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./JOJOStorage.sol";
import "../utils/Errors.sol";
import "../lib/Types.sol";
import "../lib/Liquidation.sol";

// ONLY OWNER FUNCTIONS
contract JOJOOperation is JOJOStorage {
    using SafeERC20 for IERC20;

    // ========== events ==========

    event HandleBadDebt(address indexed liquidatedTrader);

    event UpdateFundingRate(
        address indexed perp,
        int256 oldRate,
        int256 newRate
    );

    event UpdatePerpRiskParams(address indexed perp, Types.RiskParams param);

    event SetInsurance(address oldInsurance, address newInsurance);

    event SetWithdrawTimeLock(
        uint256 oldWithdrawTimeLock,
        uint256 newWithdrawTimeLock
    );

    // ========== balance related ==========

    function handleBadDebt(address liquidatedTrader) external onlyOwner {
        require(
            !Liquidation._isSafe(state, liquidatedTrader),
            Errors.ACCOUNT_IS_SAFE
        );
        require(
            state.openPositions[liquidatedTrader].length == 0,
            Errors.TRADER_STILL_IN_LIQUIDATION
        );
        state.primaryCredit[state.insurance] += state.primaryCredit[liquidatedTrader];
        state.secondaryCredit[state.insurance] += state.secondaryCredit[liquidatedTrader];
        state.primaryCredit[liquidatedTrader] = 0;
        state.secondaryCredit[liquidatedTrader] = 0;
        emit HandleBadDebt(liquidatedTrader);
    }

    // ========== params updates ==========

    function updateFundingRate(
        address[] calldata perpList,
        int256[] calldata rateList
    ) external onlyOwner {
        for (uint256 i = 0; i < perpList.length; i++) {
            Types.RiskParams storage param = state.perpRiskParams[perpList[i]];
            int256 oldRate = param.fundingRate;
            param.fundingRate = rateList[i];
            emit UpdateFundingRate(perpList[i], oldRate, rateList[i]);
        }
    }

    function setPerpRiskParams(address perp, Types.RiskParams calldata param)
        external
        onlyOwner
    {
        if (state.perpRiskParams[perp].isRegistered && !param.isRegistered) {
            // remove perp
            for (uint256 i; i < state.registeredPerp.length; i++) {
                if (state.registeredPerp[i] == perp) {
                    state.registeredPerp[i] = state.registeredPerp[
                        state.registeredPerp.length - 1
                    ];
                    state.registeredPerp.pop();
                }
            }
        }
        if (!state.perpRiskParams[perp].isRegistered && param.isRegistered) {
            // new perp
            state.registeredPerp.push(perp);
        }
        require(
            param.liquidationThreshold < 10**18 &&
                param.liquidationPriceOff < param.liquidationThreshold &&
                param.insuranceFeeRate < param.liquidationThreshold,
            Errors.INVALID_RISK_PARAM
        );
        state.perpRiskParams[perp] = param;
        emit UpdatePerpRiskParams(perp, param);
    }

    function setInsurance(address newInsurance) external onlyOwner {
        address oldInsurance = state.insurance;
        state.insurance = newInsurance;
        emit SetInsurance(oldInsurance, newInsurance);
    }

    function setWithdrawTimeLock(uint256 newWithdrawTimeLock)
        external
        onlyOwner
    {
        uint256 oldWithdrawTimeLock = state.withdrawTimeLock;
        state.withdrawTimeLock = newWithdrawTimeLock;
        emit SetWithdrawTimeLock(oldWithdrawTimeLock, newWithdrawTimeLock);
    }

    function setSecondaryAsset(address _secondaryAsset) external onlyOwner {
        require(state.secondaryAsset==address(0), Errors.SECONDARY_ASSET_ALREASY_EXIST);
        state.secondaryAsset = _secondaryAsset;
    }
}
