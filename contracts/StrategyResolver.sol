// SPDX-License-Identifier: GNU Affero
pragma solidity ^0.6.0;

import "@openzeppelin/contracts/access/Ownable.sol";

import "./interfaces/IStrategyFacade.sol";

/// @title Resolver contract for Gelato harvest bot
/// @author Tesseract Finance
contract StrategyResolver is Ownable {
    address public facade;

    event FacadeContractUpdated(address facade);

    constructor(address _facade) public {
        facade = _facade;
    }

    function setFacadeContract(address _facade) public onlyOwner {
        facade = _facade;

        emit FacadeContractUpdated(_facade);
    }

    function check(uint256 _callCost) external view returns (bool canExec, bytes memory execPayload) {
        (bool _canExec, address _strategy) = IStrategyFacade(facade).checkHarvest(_callCost);

        canExec = _canExec;

        execPayload = abi.encodeWithSelector(IStrategyFacade.harvest.selector, address(_strategy));
    }
}
