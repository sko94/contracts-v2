certoraRun.py contracts/external/actions/AccountAction.sol \\n\tcontracts/mocks/certora/BalanceStateHarness.sol \\n\tcontracts/mocks/certora/DummyERC20A.sol \\n \t--verify BalanceStateHarness:certora/asset/BalanceState.spec \\n \t--solc solc7.6 \\n\t--optimistic_loop \\n \t--loop_iter 1 \\n\t--cache BalanceHandlerNotional \\n\t--packages_path ${BROWNIE_PATH}/packages \\n\t--packages @openzeppelin=${BROWNIE_PATH}/packages/OpenZeppelin/openzeppelin-contracts@3.4.0-solc-0.7 compound-finance=${BROWNIE_PATH}/packages/compound-finance \\n \t--solc_args "['--optimize']" --msg "BalanceState - $1" --javaArgs '"-Dverbose.times -Dverbose.cache"' --staging --rule integrity_depositAssetToken_old
