pragma solidity 0.8.12;

// Perpetual
// 1. report - balanceOf
// 2. modif - trade
// 3. modify - liquidate
// 4. modify - changeCredit

interface IPerpetual {
    function balanceOf(address trader)
        external
        view
        returns (int256 paperAmount, int256 credit);

    function trade(
        bytes calldata tradeData
    ) external;

    function liquidate(address brokenTrader, int256 liquidatePaperAmount)
        external;

    function changeCredit(address trader, int256 amount) external;
}
