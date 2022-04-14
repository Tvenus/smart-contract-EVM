/*
    Copyright 2022 JOJO Exchange
    SPDX-License-Identifier: Apache-2.0
*/

pragma solidity 0.8.9;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "../intf/IPerpetual.sol";
import "../intf/ISubaccount.sol";
import "../utils/SignedDecimalMath.sol";
import "../utils/Errors.sol";
import "./Liquidation.sol";
import "./EIP712.sol";
import "./Types.sol";

library Trading {
    using SignedDecimalMath for int256;
    using Math for uint256;

    // if the order is long, orderFilledPaperAmount>0 and filledCreditAmount<0
    // if sender charge fee from this order, fee>0
    // if sender provide rebate to this order, fee<0
    event OrderFilled(
        bytes32 indexed orderHash,
        address indexed trader,
        address indexed perp,
        int256 orderFilledPaperAmount,
        int256 filledCreditAmount,
        uint256 positionSerialNum
    );

    event RelayerFeeCollected(address indexed relayer, int256 fee);

    function _approveTrade(
        Types.State storage state,
        address orderSender,
        bytes calldata tradeData
    ) public returns (Types.MatchResult memory result) {
        result.perp = msg.sender;
        require(
            state.perpRiskParams[result.perp].isRegistered,
            Errors.PERP_NOT_REGISTERED
        );
        // first taker and following multiple makers
        // orderList >= 2
        // matchPaperAmount.length = orderList.length
        // matchPaperAmount[0] = summary of the following
        (
            Types.Order[] memory orderList,
            bytes[] memory signatureList,
            uint256[] memory matchPaperAmount
        ) = abi.decode(tradeData, (Types.Order[], bytes[], uint256[]));

        // validate orders
        bytes32[] memory orderHashList = new bytes32[](orderList.length);
        for (uint256 i = 0; i < orderList.length; i++) {
            orderHashList[i] = _validateOrder(
                state.domainSeparator,
                orderList[i],
                signatureList[i]
            );
            require(orderList[i].perp == result.perp, Errors.PERP_MISMATCH);
            require(
                orderList[i].orderSender == orderSender ||
                    orderList[i].orderSender == address(0),
                Errors.INVALID_ORDER_SENDER
            );
            state.orderFilledPaperAmount[orderHashList[i]] += matchPaperAmount[i];
            require(
                state.orderFilledPaperAmount[orderHashList[i]] <=
                    int256(orderList[i].paperAmount).abs(),
                Errors.ORDER_FILLED_OVERFLOW
            );
            _addPosition(state, result.perp, orderList[i].signer);
        }

        // de-duplicate trader to save gas
        // traderList[0] is taker
        // traderList[1] is maker
        // traderList[2:] are other makers
        {
            uint256 uniqueTraderNum = 2;
            uint256 totalMakerFilledPaper;

            for (uint256 i = 1; i < orderList.length; i++) {
                if (i >= 2 && orderList[i].signer != orderList[i - 1].signer) {
                    uniqueTraderNum += 1;
                }
                totalMakerFilledPaper += matchPaperAmount[i];
            }
            require(
                matchPaperAmount[0] == totalMakerFilledPaper,
                Errors.TAKER_TRADE_AMOUNT_WRONG
            );
            require(uniqueTraderNum >= 2, Errors.INVALID_TRADER_NUMBER);
            result.traderList = new address[](uniqueTraderNum);
            result.traderList[0] = orderList[0].signer;
        }

        // validate maker order & merge paper amount
        result.paperChangeList = new int256[](result.traderList.length);
        result.creditChangeList = new int256[](result.traderList.length);
        {
            uint256 currentTraderIndex = 1;
            result.traderList[1] = orderList[1].signer;
            for (uint256 i = 1; i < orderList.length; i++) {
                _priceMatchCheck(orderList[0], orderList[i]);

                // welcome new maker
                if (i >= 2 && orderList[i].signer != orderList[i - 1].signer) {
                    currentTraderIndex += 1;
                    result.traderList[currentTraderIndex] = orderList[i].signer;
                }

                // matching result
                int256 paperChange = orderList[i].paperAmount > 0
                    ? int256(matchPaperAmount[i])
                    : -1 * int256(matchPaperAmount[i]);
                int256 creditChange = (paperChange *
                    orderList[i].creditAmount) / orderList[i].paperAmount;
                int256 fee = int256(creditChange.abs()).decimalMul(
                    _info2MakerFeeRate(orderList[i].info)
                );
                uint256 serialNum = state.positionSerialNum[
                    orderList[i].signer
                ][result.perp];
                emit OrderFilled(
                    orderHashList[i],
                    orderList[i].signer,
                    result.perp,
                    paperChange,
                    creditChange - fee,
                    serialNum
                );
                result.paperChangeList[currentTraderIndex] += paperChange;
                result.creditChangeList[currentTraderIndex] += creditChange;
                result.creditChangeList[currentTraderIndex] -= fee;
                result.paperChangeList[0] -= paperChange;
                result.creditChangeList[0] -= creditChange;
                result.orderSenderFee += fee;
            }
        }

        // trading fee related
        {
            int256 takerFee = int256(result.creditChangeList[0].abs())
                .decimalMul(_info2TakerFeeRate(orderList[0].info));
            result.creditChangeList[0] -= takerFee;
            result.orderSenderFee += takerFee;
            state.primaryCredit[orderSender] += result.orderSenderFee;
            if (result.orderSenderFee < 0) {
                require(
                    Liquidation._isSafe(state, orderSender),
                    Errors.ORDER_SENDER_NOT_SAFE
                );
            }
            emit RelayerFeeCollected(orderSender, result.orderSenderFee);
            emit OrderFilled(
                orderHashList[0],
                orderList[0].signer,
                result.perp,
                result.paperChangeList[0],
                result.creditChangeList[0],
                state.positionSerialNum[orderList[0].signer][result.perp]
            );
        }
    }

    function _priceMatchCheck(
        Types.Order memory takerOrder,
        Types.Order memory makerOrder
    ) private pure {
        require(takerOrder.perp == makerOrder.perp, Errors.PERP_MISMATCH);
        // require
        // takercredit * abs(makerpaper) / abs(takerpaper) + makercredit <= 0
        // makercredit - takercredit * makerpaper / takerpaper <= 0
        // if takerPaper > 0
        // makercredit * takerpaper <= takercredit * makerpaper
        // if takerPaper < 0
        // makercredit * takerpaper >= takercredit * makerpaper

        // let temp1 = makercredit * takerpaper
        // let temp2 = takercredit * makerpaper
        int256 temp1 = int256(makerOrder.creditAmount) *
            int256(takerOrder.paperAmount);
        int256 temp2 = int256(takerOrder.creditAmount) *
            int256(makerOrder.paperAmount);
        if (takerOrder.paperAmount > 0) {
            // taker open long, tradePaperAmount > 0
            require(makerOrder.paperAmount < 0, Errors.ORDER_PRICE_NOT_MATCH);
            require(temp1 <= temp2, Errors.ORDER_PRICE_NOT_MATCH);
        } else {
            // taker open short, tradePaperAmount < 0
            require(makerOrder.paperAmount > 0, Errors.ORDER_PRICE_NOT_MATCH);
            require(temp1 >= temp2, Errors.ORDER_PRICE_NOT_MATCH);
        }
    }

    function _addPosition(
        Types.State storage state,
        address perp,
        address trader
    ) private {
        if (!state.hasPosition[trader][perp]) {
            state.hasPosition[trader][perp] = true;
            state.openPositions[trader].push(perp);
        }
    }

    function _structHash(Types.Order memory order)
        public
        pure
        returns (bytes32 structHash)
    {
        /*
         *keccak256(
         *    abi.encode(
         *        Types.ORDER_TYPEHASH,
         *        order.perp,
         *        order.signer,
         *        order.orderSender,
         *        order.paperAmount,
         *        order.creditAmount,
         *        order.info
         *    )
         *)
         */

        bytes32 orderTypeHash = Types.ORDER_TYPEHASH;
        assembly {
            let start := sub(order, 32)
            let tmp := mload(start)
            // 224 = (1 + 6) * 32
            // [0...32)   bytes: EIP712_ORDER_TYPE
            // [32...224) bytes: order
            mstore(start, orderTypeHash)
            structHash := keccak256(start, 224)
            mstore(start, tmp)
        }
    }

    function _getOrderHash(bytes32 domainSeparator, Types.Order memory order)
        public
        pure
        returns (bytes32 orderHash)
    {
        orderHash = EIP712._hashTypedDataV4(
            domainSeparator,
            _structHash(order)
        );
    }

    function _validateOrder(
        bytes32 domainSeparator,
        Types.Order memory order,
        bytes memory signature
    ) public returns (bytes32 orderHash) {
        orderHash = EIP712._hashTypedDataV4(
            domainSeparator,
            _structHash(order)
        );
        if (Address.isContract(order.signer)) {
            require(
                ISubaccount(order.signer).isValidPerpetualOperator(
                    ECDSA.recover(orderHash, signature)
                ),
                Errors.INVALID_ORDER_SIGNATURE
            );
        } else {
            require(
                ECDSA.recover(orderHash, signature) == order.signer,
                Errors.INVALID_ORDER_SIGNATURE
            );
        }
        require(
            _info2Expiration(order.info) >= block.timestamp,
            Errors.ORDER_EXPIRED
        );
        require(
            (order.paperAmount < 0 && order.creditAmount > 0) ||
                (order.paperAmount > 0 && order.creditAmount < 0),
            Errors.ORDER_PRICE_NEGATIVE
        );
    }

    function _info2MakerFeeRate(bytes32 info) private pure returns (int256) {
        bytes8 value = bytes8(info >> 192);
        int64 makerFee;
        assembly {
            makerFee := value
        }
        return int256(makerFee);
    }

    function _info2TakerFeeRate(bytes32 info)
        private
        pure
        returns (int256 takerFeeRate)
    {
        bytes8 value = bytes8(info >> 128);
        int64 takerFee;
        assembly {
            takerFee := value
        }
        return int256(takerFee);
    }

    function _info2Expiration(bytes32 info) private pure returns (uint256) {
        bytes8 value = bytes8(info >> 64);
        uint64 expiration;
        assembly {
            expiration := value
        }
        return uint256(expiration);
    }
}
