// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.7.6;
pragma abicoder v2;

import {
    Token,
    PrimeRate,
    PrimeCashFactors,
    RebalancingContextStorage
} from "../../global/Types.sol";
import {StorageLayoutV2} from "../../global/StorageLayoutV2.sol";
import {LibStorage} from "../../global/LibStorage.sol";
import {Constants} from "../../global/Constants.sol";
import {SafeInt256} from "../../math/SafeInt256.sol";
import {SafeUint256} from "../../math/SafeUint256.sol";

import {BalanceHandler} from "../../internal/balances/BalanceHandler.sol";
import {PrimeRateLib} from "../../internal/pCash/PrimeRateLib.sol";
import {TokenHandler} from "../../internal/balances/TokenHandler.sol";
import {nTokenHandler} from "../../internal/nToken/nTokenHandler.sol";
import {nTokenSupply} from "../../internal/nToken/nTokenSupply.sol";
import {PrimeCashExchangeRate, PrimeCashFactors} from "../../internal/pCash/PrimeCashExchangeRate.sol";
import {GenericToken} from "../../internal/balances/protocols/GenericToken.sol";

import {ActionGuards} from "./ActionGuards.sol";
import {NotionalTreasury} from "../../../interfaces/notional/NotionalTreasury.sol";
import {Comptroller} from "../../../interfaces/compound/ComptrollerInterface.sol";
import {CErc20Interface} from "../../../interfaces/compound/CErc20Interface.sol";
import {IPrimeCashHoldingsOracle, DepositData, RedeemData} from "../../../interfaces/notional/IPrimeCashHoldingsOracle.sol";
import {IRebalancingStrategy, RebalancingData} from "../../../interfaces/notional/IRebalancingStrategy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

contract TreasuryAction is StorageLayoutV2, ActionGuards, NotionalTreasury {
    using SafeUint256 for uint256;
    using SafeInt256 for int256;
    using SafeERC20 for IERC20;
    using TokenHandler for Token;

    IERC20 public immutable COMP;
    Comptroller public immutable COMPTROLLER;

    /// @dev Harvest methods are only callable by the authorized treasury manager contract
    modifier onlyManagerContract() {
        require(treasuryManagerContract == msg.sender, "Treasury manager required");
        _;
    }

    constructor(Comptroller _comptroller) {
        COMPTROLLER = _comptroller;
        COMP = IERC20(_comptroller.getCompAddress());
    }

    /// @notice Sets the new treasury manager contract
    function setTreasuryManager(address manager) external override onlyOwner {
        emit TreasuryManagerChanged(treasuryManagerContract, manager);
        treasuryManagerContract = manager;
    }

    /// @notice Sets the reserve buffer. This is the amount of reserve balance to keep denominated in 1e8
    /// The reserve cannot be harvested if it's below this amount. This portion of the reserve will remain on
    /// the contract to act as a buffer against potential insolvency.
    /// @param currencyId refers to the currency of the reserve
    /// @param bufferAmount reserve buffer amount to keep in internal token precision (1e8)
    function setReserveBuffer(uint16 currencyId, uint256 bufferAmount) external override onlyOwner {
        _checkValidCurrency(currencyId);
        reserveBuffer[currencyId] = bufferAmount;
        emit ReserveBufferUpdated(currencyId, bufferAmount);
    }

    /// @notice This is used in the case of insolvency. It allows the owner to re-align the reserve with its correct balance.
    /// @param currencyId refers to the currency of the reserve
    /// @param newBalance new reserve balance to set, must be less than the current balance
    function setReserveCashBalance(uint16 currencyId, int256 newBalance)
        external
        override
        onlyOwner
    {
        _checkValidCurrency(currencyId);
        // newBalance cannot be negative and is checked inside BalanceHandler.setReserveCashBalance
        BalanceHandler.setReserveCashBalance(currencyId, newBalance);
    }

    /// @notice Claims COMP incentives earned and transfers to the treasury manager contract.
    /// @param cTokens a list of cTokens to claim incentives for
    /// @return the balance of COMP claimed
    function claimCOMPAndTransfer(address[] calldata cTokens)
        external
        override
        onlyManagerContract
        nonReentrant
        returns (uint256)
    {
        COMPTROLLER.claimComp(address(this), cTokens);
        // NOTE: If Notional ever lists COMP as a collateral asset it will be cCOMP instead and it
        // will never hold COMP balances directly. In this case we can always transfer all the COMP
        // off of the contract.
        uint256 bal = COMP.balanceOf(address(this));
        // NOTE: the onlyManagerContract modifier prevents a transfer to address(0) here
        if (bal > 0) COMP.safeTransfer(msg.sender, bal);
        // NOTE: TreasuryManager contract will emit a COMPHarvested event
        return bal;
    }

    /// @notice redeems and transfers tokens to the treasury manager contract
    function _redeemAndTransfer(
        uint16 currencyId,
        Token memory asset,
        int256 assetInternalRedeemAmount
    ) private returns (uint256) {
        int256 assetExternalRedeemAmount = asset.convertToExternal(assetInternalRedeemAmount);

        // This is the actual redeemed amount in underlying external precision
        // NOTE: asset.redeem will return a negative number to represent that assets have left the
        // contract, convert to a positive uint here. asset.redeem() will also transfer the underlying
        // to the treasuryManagerContract
        uint256 redeemedExternalUnderlying = asset
            .redeem(currencyId, treasuryManagerContract, assetExternalRedeemAmount.toUint())
            .neg()
            .toUint();

        return redeemedExternalUnderlying;
    }

    /// @notice Transfers some amount of reserve assets to the treasury manager contract to be invested
    /// into the sNOTE pool.
    /// @param currencies an array of currencies to transfer from Notional
    function transferReserveToTreasury(uint16[] calldata currencies)
        external
        override
        onlyManagerContract
        nonReentrant
        returns (uint256[] memory)
    {
        uint256[] memory amountsTransferred = new uint256[](currencies.length);

        for (uint256 i; i < currencies.length; ++i) {
            // Prevents duplicate currency IDs
            if (i > 0) require(currencies[i] > currencies[i - 1], "IDs must be sorted");

            uint16 currencyId = currencies[i];

            _checkValidCurrency(currencyId);

            // Reserve buffer amount in INTERNAL_TOKEN_PRECISION
            int256 bufferInternal = SafeInt256.toInt(reserveBuffer[currencyId]);

            // Reserve requirement not defined
            if (bufferInternal == 0) continue;

            int256 reserveInternal = BalanceHandler.getPositiveCashBalance(Constants.FEE_RESERVE, currencyId);

            // Do not withdraw anything if reserve is below or equal to reserve requirement
            if (reserveInternal <= bufferInternal) continue;

            // Actual reserve amount allowed to be redeemed and transferred
            // NOTE: overflow not possible with the check above
            int256 primeCashRedeemed = reserveInternal - bufferInternal;

            // Redeems prime cash and transfer underlying to treasury manager contract
            amountsTransferred[i] = _redeemAndTransfer(currencyId, primeCashRedeemed);

            // Updates the reserve balance
            BalanceHandler.harvestExcessReserveBalance(
                currencyId,
                reserveInternal,
                primeCashRedeemed
            );
        }

        // NOTE: TreasuryManager contract will emit an AssetsHarvested event
        return amountsTransferred;
    }
}
