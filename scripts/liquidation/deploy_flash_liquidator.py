import json
from brownie import NotionalV2FlashLiquidator, accounts, network
from scripts.liquidation.liquidation_config import LiquidationConfig

def main():
    lender = "AaveFlashLender"
    deployer = accounts.load(network.show_active().upper() + "_DEPLOYER")
    config = LiquidationConfig[network.show_active()]
    liquidator = NotionalV2FlashLiquidator.deploy(
        config["NotionalV2"], 
        config[lender], 
        config["WETH"], 
        config["cETH"], 
        deployer.address,
        config["UniswapRouter"],  
        {"from": deployer}
    )
    liquidator.setCTokenAddress(config["cDAI"], {"from": deployer})
    liquidator.setCTokenAddress(config["cUSDC"], {"from": deployer})
    liquidator.setCTokenAddress(config["cWBTC"], {"from": deployer})
    liquidator.approveToken(config["cETH"], config["NotionalV2"], {"from": deployer})
    liquidator.approveToken(config["WETH"], config[lender], {"from": deployer})
    liquidator.approveToken(config["WETH"], config["UniswapRouter"], {"from": deployer})
    liquidator.approveToken(config["DAI"], config[lender], {"from": deployer})
    liquidator.approveToken(config["DAI"], config["UniswapRouter"], {"from": deployer})
    liquidator.approveToken(config["USDC"], config[lender], {"from": deployer})
    liquidator.approveToken(config["USDC"], config["UniswapRouter"], {"from": deployer})
    liquidator.approveToken(config["WBTC"], config[lender], {"from": deployer})
    liquidator.approveToken(config["WBTC"], config["UniswapRouter"], {"from": deployer})

    output_file = "v2.flash.{}.json".format(network.show_active())
    with open(output_file, "w") as f:
        json.dump(
            {
                "flashLiquidator": liquidator.address
            },
            f,
            sort_keys=True,
            indent=4,
        )
