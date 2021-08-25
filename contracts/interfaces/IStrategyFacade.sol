// SPDX-License-Identifier: GNU Affero
pragma solidity ^0.6.0;

/// @title StrategyFacade Interface
/// @author Tesseract Finance
interface IStrategyFacade {
    /**
     * Checks if any of the strategies should be harvested
     * @dev :_callCost: must be priced in terms of wei (1e-18 ETH)
     *
     * @param _callCost - The Gelato bot's estimated gas cost to call harvest function (in wei)
     *
     * @return canExec - True if Gelato bot should harvest, false if it shouldn't
     * @return strategy - Address of the strategy contract that needs to be harvested
     */
    function checkHarvest(uint256 _callCost) external view returns (bool canExec, address strategy);

    /**
     * Call harvest function on a Strategy smart contract with the given address
     *
     * @param _strategy - Address of a Strategy smart contract which needs to be harvested
     *
     * No return, reverts on error
     */
    function harvest(address _strategy) external;
}
