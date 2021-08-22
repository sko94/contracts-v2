// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../../internal/markets/AssetRate.sol";
import "../../internal/AccountContextHandler.sol";
import "../../internal/portfolio/PortfolioHandler.sol";
import "../../internal/portfolio/BitmapAssetsHandler.sol";
import "../../internal/settlement/SettlePortfolioAssets.sol";
import "../../external/SettleAssetsExternal.sol";

contract SettlementHarness {
    using AssetHandler for PortfolioAsset;
    using AccountContextHandler for AccountContext;

    AccountContext symbolicAccountContext;
    PortfolioState symbolicPortfolioState;

    function getBitmapCurrencyId(address account) external view returns (uint256) {
        return symbolicAccountContext.bitmapCurrencyId;
    }

    function getBitNumFromMaturity(uint256 blockTime, uint256 maturity)
        public
        pure
        returns (uint256, bool)
    {
        return DateTime.getBitNumFromMaturity(blockTime, maturity);
    }

    function getMaturityFromBitNum(uint256 blockTime, uint256 bitNum)
        public
        pure
        returns (uint256)
    {
        return DateTime.getMaturityFromBitNum(blockTime, bitNum);
    }

    function getSettlementRate(uint256 currencyId, uint256 maturity)
        external
        view
        returns (int256)
    {
        AssetRateParameters memory ar = AssetRate.buildSettlementRateView(currencyId, maturity);
        return ar.rate;
    }

    function getCashBalance(address account, uint256 currencyId) external view returns (int256) {
        BalanceState memory balanceState;
        BalanceHandler.loadBalanceState(balanceState, account, currencyId, symbolicAccountContext);

        return balanceState.storedCashBalance;
    }

    function _getAccountAssets(address account) internal view returns (PortfolioAsset[] memory) {
        if (symbolicAccountContext.bitmapCurrencyId == 0) {
            return symbolicPortfolioState.storedAssets;
        } else {
            return
                BitmapAssetsHandler.getifCashArray(
                    account,
                    symbolicAccountContext.bitmapCurrencyId,
                    symbolicAccountContext.nextSettleTime
                );
        }
    }

    function getNumSettleableAssets(address account, uint256 blockTime)
        external
        view
        returns (uint256)
    {
        uint256 numSettleableAssets;
        PortfolioAsset[] memory assets = _getAccountAssets(account);

        for (uint256 i; i < assets.length; i++) {
            if (assets[i].getSettlementDate() <= blockTime) numSettleableAssets++;
        }

        return numSettleableAssets;
    }

    function getAmountToSettle(
        uint256 currencyId,
        address account,
        uint256 blockTime
    ) external view returns (int256) {
        int256 amountToSettle;
        PortfolioAsset[] memory assets = _getAccountAssets(account);
        for (uint256 i; i < assets.length; i++) {
            // TODO: incomplete, but is this even the right approach?
            if (assets[i].getSettlementDate() <= blockTime && assets[i].currencyId == currencyId) {
                // AssetRate memory ar = AssetRate.buildSettlementRateView(currencyId, maturity);
            }
        }

        return amountToSettle;
    }

    function getNumAssets(address account) external view returns (uint256) {
        PortfolioAsset[] memory assets = _getAccountAssets(account);
        // Value of any asset should never be zero. If it is then it should not exist in the portfolio.
        for (uint256 i; i < assets.length; i++) assert(assets[i].notional != 0);
        return assets.length;
    }

    function settleAccount(address account) external {
        // This is an approximation of what happens in SettleAssetsExternal._settleAccount
        SettleAmount[] memory settleAmounts;

        if (symbolicAccountContext.bitmapCurrencyId != 0) {
            settleAmounts = SettleAssetsExternal._settleBitmappedAccountStateful(
                account,
                symbolicAccountContext
            );
        } else {
            settleAmounts = SettlePortfolioAssets.settlePortfolio(
                symbolicPortfolioState,
                block.timestamp
            );

            symbolicAccountContext.storeAssetsAndUpdateContext(
                account,
                symbolicPortfolioState,
                false
            );
        }

        BalanceHandler.finalizeSettleAmounts(account, symbolicAccountContext, settleAmounts);
    }

    function setifCashAsset(
        address account,
        uint256 currencyId,
        uint256 maturity,
        uint256 nextSettleTime,
        int256 notional
    ) external returns (int256) {
        bytes32 bitmap = BitmapAssetsHandler.getAssetsBitmap(account, currencyId);
        (bytes32 newBitmap, int256 finalNotional) = BitmapAssetsHandler.addifCashAsset(
            account,
            currencyId,
            maturity,
            nextSettleTime,
            notional,
            bitmap
        );
        BitmapAssetsHandler.setAssetsBitmap(account, currencyId, newBitmap);

        return finalNotional;
    }

    function validateAssetExists(
        address account,
        uint256 maturity,
        int256 notional
    ) public view returns (bool) {
        PortfolioAsset[] memory assets = _getAccountAssets(account);
        for (uint256 i; i < assets.length; i++) {
            if (assets[i].maturity == maturity && assets[i].notional == notional) return true;
        }

        return false;
    }
}