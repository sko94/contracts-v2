import random

import brownie
import pytest
from brownie.test import given, strategy
from tests.constants import (
    BASIS_POINT,
    CASH_GROUP_PARAMETERS,
    NORMALIZED_RATE_TIME,
    SECONDS_IN_DAY,
    START_TIME,
)
from tests.helpers import get_cash_group_with_max_markets, get_market_state, get_tref


@pytest.fixture(scope="module", autouse=True)
def mockCToken(MockCToken, accounts):
    ctoken = accounts[0].deploy(MockCToken, 8)
    ctoken.setAnswer(1e18)
    return ctoken


@pytest.fixture(scope="module", autouse=True)
def aggregator(cTokenAggregator, mockCToken, accounts):
    return cTokenAggregator.deploy(mockCToken.address, {"from": accounts[0]})


@pytest.fixture(scope="module", autouse=True)
def cashGroup(MockCashGroup, accounts):
    return accounts[0].deploy(MockCashGroup)


@pytest.fixture(autouse=True)
def isolation(fn_isolation):
    pass


def test_invalid_max_market_index_settings(cashGroup):
    cashGroupParameters = list(CASH_GROUP_PARAMETERS)

    with brownie.reverts():
        # Cannot set max markets to 1
        cashGroupParameters[0] = 1
        cashGroup.setCashGroup(1, cashGroupParameters)

    with brownie.reverts():
        # Cannot set max markets past max value
        cashGroupParameters[0] = 10
        cashGroup.setCashGroup(1, cashGroupParameters)

    with brownie.reverts():
        # Cannot reduce max markets
        cashGroupParameters[0] = 4
        cashGroup.setCashGroup(1, cashGroupParameters)
        cashGroupParameters[0] = 3
        cashGroup.setCashGroup(1, cashGroupParameters)


def test_invalid_rate_scalar_settings(cashGroup):
    cashGroupParameters = list(CASH_GROUP_PARAMETERS)

    with brownie.reverts():
        # invalid length
        cashGroupParameters[0] = 3
        cashGroupParameters[7] = []
        cashGroup.setCashGroup(1, cashGroupParameters)

    with brownie.reverts():
        # cannot have zeros
        cashGroupParameters[0] = 3
        cashGroupParameters[7] = [10, 9, 0]
        cashGroup.setCashGroup(1, cashGroupParameters)


def test_invalid_liquidity_haircut_settings(cashGroup):
    cashGroupParameters = list(CASH_GROUP_PARAMETERS)

    with brownie.reverts():
        # invalid length
        cashGroupParameters[0] = 3
        cashGroupParameters[8] = []
        cashGroup.setCashGroup(1, cashGroupParameters)

    with brownie.reverts():
        # cannot have more than 100
        cashGroupParameters[0] = 3
        cashGroupParameters[8] = [102, 50, 50]
        cashGroup.setCashGroup(1, cashGroupParameters)


def test_build_cash_group(cashGroup, aggregator):
    # This is not tested, just used to ensure that it exists
    rateStorage = (aggregator.address, 18)

    for i in range(1, 50):
        cashGroup.setAssetRateMapping(i, rateStorage)
        maxMarketIndex = random.randint(0, 9)
        maxMarketIndex = 3
        cashGroupParameters = (
            maxMarketIndex,
            random.randint(1, 255),  # 1 rateOracleTimeWindowMin,
            random.randint(1, 255),  # 2 liquidityFeeBPS,
            random.randint(1, 255),  # 3 debtBuffer5BPS,
            random.randint(1, 255),  # 4 fCashHaircut5BPS,
            random.randint(1, 255),  # 4 settlement penalty bps,
            random.randint(1, 255),  # 5 liquidity repo discount bps,
            # 7: token haircuts (percentages)
            tuple([100 - i for i in range(0, maxMarketIndex)]),
            # 8: rate scalar (increments of 10)
            tuple([10 - i for i in range(0, maxMarketIndex)]),
        )

        cashGroup.setCashGroup(i, cashGroupParameters)

        (cg, markets) = cashGroup.buildCashGroup(i)
        assert cg[0] == i  # cash group id
        assert cg[1] == cashGroupParameters[0]  # Max market index
        # assert cg[3] == "0x" + cashGroupBytes
        assert len(markets) == cg[1]

        assert cashGroupParameters[1] * 60 == cashGroup.getRateOracleTimeWindow(cg)
        assert cashGroupParameters[2] * BASIS_POINT == cashGroup.getLiquidityFee(
            cg, NORMALIZED_RATE_TIME
        )
        assert cashGroupParameters[3] * 5 * BASIS_POINT == cashGroup.getDebtBuffer(cg)
        assert cashGroupParameters[4] * 5 * BASIS_POINT == cashGroup.getfCashHaircut(cg)
        assert cashGroupParameters[5] * 5 * BASIS_POINT == cashGroup.getSettlementPenalty(cg)
        assert cashGroupParameters[6] * 5 * BASIS_POINT == cashGroup.getLiquidityTokenRepoDiscount(
            cg
        )

        for m in range(0, maxMarketIndex):
            assert cashGroupParameters[7][m] == cashGroup.getLiquidityHaircut(cg, m + 2)
            assert cashGroupParameters[8][m] * 10 == cashGroup.getRateScalar(
                cg, m + 1, NORMALIZED_RATE_TIME
            )


@given(
    maxMarketIndex=strategy("uint8", min_value=2, max_value=9),
    blockTime=strategy("uint32", min_value=START_TIME),
)
def test_get_market(cashGroup, aggregator, maxMarketIndex, blockTime):
    rateStorage = (aggregator.address, 18)
    cashGroup.setAssetRateMapping(1, rateStorage)
    cashGroup.setCashGroup(1, get_cash_group_with_max_markets(maxMarketIndex))

    tRef = get_tref(blockTime)
    validMarkets = [tRef + cashGroup.getTradedMarket(i) for i in range(1, maxMarketIndex + 1)]
    (cg, markets) = cashGroup.buildCashGroup(1)

    for m in validMarkets:
        settlementDate = tRef + 90 * SECONDS_IN_DAY
        cashGroup.setMarketState(cg[0], m, settlementDate, get_market_state(m))

    (cg, markets) = cashGroup.buildCashGroup(1)

    for i in range(0, len(validMarkets)):
        needsLiquidity = True if random.randint(0, 1) else False
        market = cashGroup.getMarket(cg, markets, i + 1, blockTime, needsLiquidity)
        marketStored = cashGroup.getMarketState(cg[0], validMarkets[i], blockTime, 1)

        # Assert values are the same
        assert market[2] == marketStored[2]
        assert market[3] == marketStored[3]
        if needsLiquidity:
            assert market[4] == marketStored[4]
        else:
            assert market[4] == 0

        assert market[5] == marketStored[5]
        # NOTE: don't need to test oracleRate
        assert market[7] == marketStored[7]
        # Assert market has updated is set to false
        assert market[8] == "0x00"


@given(
    maxMarketIndex=strategy("uint8", min_value=2, max_value=9),
    blockTime=strategy("uint32", min_value=START_TIME),
    # this is a per block interest rate of 0.2% to 42%, (rate = 2102400 * supplyRate / 1e18)
    supplyRate=strategy("uint", min_value=1e9, max_value=2e11),
)
def test_get_oracle_rate(cashGroup, aggregator, mockCToken, maxMarketIndex, blockTime, supplyRate):
    mockCToken.setSupplyRate(supplyRate)
    cRate = supplyRate * 2102400 / 1e9

    rateStorage = (aggregator.address, 18)
    cashGroup.setAssetRateMapping(1, rateStorage)
    cashGroup.setCashGroup(1, get_cash_group_with_max_markets(maxMarketIndex))

    tRef = get_tref(blockTime)
    validMarkets = [tRef + cashGroup.getTradedMarket(i) for i in range(1, maxMarketIndex + 1)]
    impliedRates = {}
    (cg, markets) = cashGroup.buildCashGroup(1)

    for m in validMarkets:
        lastImpliedRate = random.randint(1e8, 1e9)
        impliedRates[m] = lastImpliedRate
        settlementDate = tRef + 90 * SECONDS_IN_DAY

        cashGroup.setMarketState(
            cg[0],
            m,
            settlementDate,
            get_market_state(
                m, lastImpliedRate=lastImpliedRate, previousTradeTime=blockTime - 1000
            ),
        )

    for m in validMarkets:
        # If we fall on a valid market then the rate must match exactly
        rate = cashGroup.getOracleRate(cg, markets, m, blockTime)
        assert rate == impliedRates[m]

    for i in range(0, 5):
        randomM = random.randint(blockTime + 1, validMarkets[-1])
        rate = cashGroup.getOracleRate(cg, markets, randomM, blockTime)
        (marketIndex, idiosyncratic) = cashGroup.getMarketIndex(cg, randomM, blockTime)

        if not idiosyncratic:
            assert rate == impliedRates[randomM]
        elif marketIndex != 1:
            shortM = validMarkets[marketIndex - 2]
            longM = validMarkets[marketIndex - 1]
            assert rate > min(impliedRates[shortM], impliedRates[longM])
            assert rate < max(impliedRates[shortM], impliedRates[longM])
        else:
            assert rate > min(cRate, impliedRates[validMarkets[0]])
            assert rate < max(cRate, impliedRates[validMarkets[0]])