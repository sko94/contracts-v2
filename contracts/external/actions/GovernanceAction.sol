// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../../common/ExchangeRate.sol";
import "../../common/CashGroup.sol";
import "../../common/PerpetualToken.sol";
import "../../storage/TokenHandler.sol";
import "../../storage/StorageLayoutV1.sol";
import "../adapters/nTokenERC20Proxy.sol";
import "interfaces/notional/AssetRateAdapter.sol";
import "@openzeppelin/contracts/utils/Create2.sol";

/// @notice Governance methods can only be called by the governance contract
contract GovernanceAction is StorageLayoutV1 {
    using AccountContextHandler for AccountStorage;

    // Emitted when a new currency is listed
    event ListCurrency(uint16 newCurrencyId);
    event UpdateETHRate(uint16 currencyId);
    event UpdateAssetRate(uint16 currencyId);
    event UpdateCashGroup(uint16 currencyId);
    event DeployNToken(uint16 currencyId, address nTokenAddress);
    event UpdateDepositParameters(uint16 currencyId);
    event UpdateInitializationParameters(uint16 currencyId);
    event UpdateIncentiveEmissionRate(uint16 currencyId, uint32 newEmissionRate);
    event UpdateTokenCollateralParameters(uint16 currencyId);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /// @dev Throws if called by any account other than the owner.
    modifier onlyOwner() {
        require(owner == msg.sender, "Ownable: caller is not the owner");
        _;
    }

    /// @dev Transfers ownership of the contract to a new account (`newOwner`).
    /// Can only be called by the current owner.
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Ownable: new owner is the zero address");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    /// @notice Lists a new currency along with its exchange rate to ETH
    /// @dev emit:ListCurrency emit:UpdateETHRate
    /// @param assetToken the token parameters for the asset token
    /// @param underlyingToken the underlying token (if asset token is an interest bearing wrapper)
    /// @param rateOracle ETH to underlying rate oracle
    /// @param mustInvert if the rate from the oracle needs to be inverted
    /// @param buffer multiplier (>= 100) for negative balances when calculating free collateral
    /// @param haircut multiplier (<= 100) for positive balances when calculating free collateral
    /// @param liquidationDiscount multiplier (>= 100) for exchange rate when liquidating
    function listCurrency(
        TokenStorage calldata assetToken,
        TokenStorage calldata underlyingToken,
        address rateOracle,
        bool mustInvert,
        uint8 buffer,
        uint8 haircut,
        uint8 liquidationDiscount
    ) external onlyOwner {
        uint16 currencyId = maxCurrencyId + 1;
        // Set the new max currency id
        maxCurrencyId = currencyId;
        require(currencyId <= maxCurrencyId, "G: max currency overflow");
        // TODO: should check for listing of duplicate tokens?

        // Set the underlying first because the asset token may set an approval using the underlying
        if (
            underlyingToken.tokenAddress != address(0) ||
            // Ether has a token address of zero
            underlyingToken.tokenType == TokenType.Ether
        ) {
            TokenHandler.setToken(currencyId, true, underlyingToken);
        }
        TokenHandler.setToken(currencyId, false, assetToken);

        _updateETHRate(currencyId, rateOracle, mustInvert, buffer, haircut, liquidationDiscount);

        emit ListCurrency(currencyId);
    }

    /// @notice Enables a cash group on a given currency so that it can have lend and borrow markets. Will
    /// also deploy an nToken contract so that markets can be initialized.
    /// @dev emit:UpdateCashGroup emit:UpdateAssetRate emit:DeployNToken
    /// @param currencyId id of the currency to enable
    /// @param assetRateOracle address of the rate oracle for converting interest bearing assets to
    /// underlying values
    /// @param cashGroup parameters for the cash group
    function enableCashGroup(
        uint16 currencyId,
        address assetRateOracle,
        CashGroupParameterStorage calldata cashGroup
    ) external onlyOwner {
        _updateCashGroup(currencyId, cashGroup);
        _updateAssetRate(currencyId, assetRateOracle);

        // Creates the nToken erc20 proxy that routes back to the main contract
        string memory name;
        string memory symbol;
        address nTokenAddress =
            Create2.deploy(
                0,
                bytes32(uint256(currencyId)),
                abi.encodePacked(
                    type(nTokenERC20Proxy).creationCode,
                    abi.encode(address(this), currencyId, name, symbol)
                )
            );

        PerpetualToken.setPerpetualTokenAddress(currencyId, nTokenAddress);
        emit DeployNToken(currencyId, nTokenAddress);
    }

    /// @notice Updates the deposit parameters for an nToken
    /// @dev emit:UpdateDepositParameters
    /// @param currencyId the currency id that the nToken references
    /// @param depositShares an array of values that represent the proportion of each deposit
    /// that will go to a respective market, must add up to DEPOSIT_PERCENT_BASIS. For example,
    /// 0.40e8, 0.40e8 and 0.20e8 will result in 40%, 40% and 20% deposited as liquidity into
    /// the 3 month, 6 month and 1 year markets.
    /// @param leverageThresholds an array of values denominated in RATE_PRECISION that mark the
    /// highest proportion of fCash where the nToken will provide liquidity. Above this proportion,
    /// the nToken will lend to the market instead to reduce the leverage in the market.
    function updateDepositParameters(
        uint16 currencyId,
        uint32[] calldata depositShares,
        uint32[] calldata leverageThresholds
    ) external onlyOwner {
        PerpetualToken.setDepositParameters(currencyId, depositShares, leverageThresholds);
        emit UpdateDepositParameters(currencyId);
    }

    /// @notice Updates the market initialization parameters for an nToken
    /// @dev emit:UpdateInitializationParameters
    /// @param currencyId the currency id that the nToken references
    /// @param rateAnchors sets the offset from the x-axis where the liquidity curve will be
    /// initialized. This is used in combination with previous market rates to determine the
    /// initial proportion where markets will be initialized every quarter. Denominated in
    /// RATE_PRECISION as an exchange rate (i.e. must be > RATE_PRECISION)
    /// @param proportions used to combination with rateAnchors set the initial proportion when
    /// a market is first initialized. This is required since there is no previous rate to reference.
    function updateInitializationParameters(
        uint16 currencyId,
        uint32[] calldata rateAnchors,
        uint32[] calldata proportions
    ) external onlyOwner {
        PerpetualToken.setInitializationParameters(currencyId, rateAnchors, proportions);
        emit UpdateInitializationParameters(currencyId);
    }

    /// @notice Updates the emission rate of incentives for a given currency
    /// @dev emit:UpdateIncentiveEmissionRate
    /// @param currencyId the currency id that the nToken references
    /// @param newEmissionRate average rate of token incentives that can be claimed for
    /// a nToken liquidity providers over a year. The rate is not exact because the total
    /// supply of tokens will fluctuate
    function updateIncentiveEmissionRate(uint16 currencyId, uint32 newEmissionRate)
        external
        onlyOwner
    {
        address nTokenAddress = PerpetualToken.nTokenAddress(currencyId);
        require(nTokenAddress != address(0), "Invalid currency");

        PerpetualToken.setIncentiveEmissionRate(nTokenAddress, newEmissionRate);
        emit UpdateIncentiveEmissionRate(currencyId, newEmissionRate);
    }

    /// @notice Updates collateralization parameters for an nToken
    /// @dev emit:UpdateTokenCollateralParameters
    /// @param currencyId the currency id that the nToken references
    /// @param residualPurchaseIncentive10BPS nTokens will have residual amounts of fCash at the end of each
    /// quarter that are "dead weight" because they are at idiosyncratic maturities and do not contribute to
    /// actively providing liquidity. This parameter incentivizes market participants to purchase these residuals
    /// at a discount from the on chain oracle rate, denominated in 10 basis point increments. These residuals will
    /// be added back into nToken balances and will be used to provide liquidity upon the next market initialization.
    /// @param pvHaircutPercentage a percentage (< 100) that the present value of the nToken's assets will be valued
    /// at for the purposes of free collateral, relevant when accounts hold nTokens as collateral against debts.
    /// @param residualPurchaseTimeBufferHours an arbitrage opportunity is available by pushing markets in one direction
    /// before quarterly settlement to generate large residual balances that can be purchased at a discount. The time buffer
    /// here ensures that anyone attempting such an act would have to wait some number of hours (likely a few days) before
    /// they could attempt to purchase residuals, ensuring that the market could realign to rates where the arbitrage is
    /// no longer possible.
    /// @param cashWithholdingBuffer10BPS nToken residuals may be negative fCash (debt), in this case cash is withheld to
    /// transfer to accounts that take on the debt. This parameter denominates the discounted rate at which the cash will
    /// be withheld at for this purpose.
    /// @param liquidationHaircutPercentage a percentage of nToken present value (> pvHaircutPercentage and <= 100) at which
    /// liquidators will purchase nTokens during liquidation
    function updateTokenCollateralParameters(
        uint16 currencyId,
        uint8 residualPurchaseIncentive10BPS,
        uint8 pvHaircutPercentage,
        uint8 residualPurchaseTimeBufferHours,
        uint8 cashWithholdingBuffer10BPS,
        uint8 liquidationHaircutPercentage
    ) external onlyOwner {
        address nTokenAddress = PerpetualToken.nTokenAddress(currencyId);
        require(nTokenAddress != address(0), "Invalid currency");

        PerpetualToken.setPerpetualTokenCollateralParameters(
            nTokenAddress,
            residualPurchaseIncentive10BPS,
            pvHaircutPercentage,
            residualPurchaseTimeBufferHours,
            cashWithholdingBuffer10BPS,
            liquidationHaircutPercentage
        );
        emit UpdateTokenCollateralParameters(currencyId);
    }

    /// @notice Updates cash group parameters
    /// @dev emit:UpdateCashGroup
    /// @param currencyId id of the currency to enable
    /// @param cashGroup new parameters for the cash group
    function updateCashGroup(uint16 currencyId, CashGroupParameterStorage calldata cashGroup)
        external
        onlyOwner
    {
        _updateCashGroup(currencyId, cashGroup);
    }

    /// @notice Updates asset rate oracle
    /// @dev emit:UpdateAssetRate
    /// @param currencyId id of the currency
    /// @param rateOracle new rate oracle for the asset
    function updateAssetRate(uint16 currencyId, address rateOracle) external onlyOwner {
        _updateAssetRate(currencyId, rateOracle);
    }

    /// @notice Updates ETH exchange rate or related parameters
    /// @dev emit:UpdateETHRate
    /// @param currencyId id of the currency
    /// @param rateOracle new rate oracle for the asset
    /// @param rateOracle ETH to underlying rate oracle
    /// @param mustInvert if the rate from the oracle needs to be inverted
    /// @param buffer multiplier (>= 100) for negative balances when calculating free collateral
    /// @param haircut multiplier (<= 100) for positive balances when calculating free collateral
    /// @param liquidationDiscount multiplier (>= 100) for exchange rate when liquidating
    function updateETHRate(
        uint16 currencyId,
        address rateOracle,
        bool mustInvert,
        uint8 buffer,
        uint8 haircut,
        uint8 liquidationDiscount
    ) external onlyOwner {
        _updateETHRate(currencyId, rateOracle, mustInvert, buffer, haircut, liquidationDiscount);
    }

    function _updateCashGroup(uint256 currencyId, CashGroupParameterStorage calldata cashGroup)
        internal
    {
        require(currencyId != 0, "G: invalid currency id");
        require(currencyId <= maxCurrencyId, "G: invalid currency id");

        CashGroup.setCashGroupStorage(currencyId, cashGroup);

        emit UpdateCashGroup(uint16(currencyId));
    }

    function _updateAssetRate(uint256 currencyId, address rateOracle) internal {
        require(currencyId != 0, "G: invalid currency id");
        require(currencyId <= maxCurrencyId, "G: invalid currency id");

        // Sanity check that the rate oracle refers to the proper asset token
        address token = AssetRateAdapter(rateOracle).token();
        Token memory assetToken = TokenHandler.getToken(currencyId, false);
        require(assetToken.tokenAddress == token, "G: invalid rate oracle");

        uint8 underlyingDecimals;
        if (currencyId == 1) {
            // If currencyId is one then this is referring to cETH and there is no underlying() to call
            underlyingDecimals = 18;
        } else {
            address underlyingToken = AssetRateAdapter(rateOracle).underlying();
            underlyingDecimals = ERC20(underlyingToken).decimals();
        }

        assetToUnderlyingRateMapping[currencyId] = AssetRateStorage({
            rateOracle: rateOracle,
            underlyingDecimalPlaces: underlyingDecimals
        });

        emit UpdateAssetRate(uint16(currencyId));
    }

    function _updateETHRate(
        uint256 currencyId,
        address rateOracle,
        bool mustInvert,
        uint8 buffer,
        uint8 haircut,
        uint8 liquidationDiscount
    ) internal {
        require(currencyId != 0, "G: invalid currency id");
        require(currencyId <= maxCurrencyId, "G: invalid currency id");

        uint8 rateDecimalPlaces;
        if (currencyId == ExchangeRate.ETH) {
            // ETH to ETH exchange rate is fixed at 1 and has no rate oracle
            rateOracle = address(0);
            rateDecimalPlaces = 18;
        } else {
            require(rateOracle != address(0), "G: zero rate oracle address");
            rateDecimalPlaces = AggregatorV2V3Interface(rateOracle).decimals();
        }
        require(buffer >= ExchangeRate.MULTIPLIER_DECIMALS, "G: buffer must be gte decimals");
        require(haircut <= ExchangeRate.MULTIPLIER_DECIMALS, "G: buffer must be lte decimals");
        require(
            liquidationDiscount > ExchangeRate.MULTIPLIER_DECIMALS,
            "G: discount must be gt decimals"
        );

        underlyingToETHRateMapping[currencyId] = ETHRateStorage({
            rateOracle: rateOracle,
            rateDecimalPlaces: rateDecimalPlaces,
            mustInvert: mustInvert,
            buffer: buffer,
            haircut: haircut,
            liquidationDiscount: liquidationDiscount
        });

        emit UpdateETHRate(uint16(currencyId));
    }
}
