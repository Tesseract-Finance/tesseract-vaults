// SPDX-License-Identifier: GNU Affero
pragma solidity ^0.6.0;

/// @title Functions from the Facade which Resolver needs to call
interface IStrategyFacade {
    function checkHarvest(uint256 _callCost) external view returns (bool canExec, address strategy);

    function harvest(address _strategy) external;
}

/// @title Resolver contract for Gelato harvest bot
/// @author Tesseract Finance
contract StrategyResolver {
    address public immutable multiSig;
    address public facade;
    uint256 public checkInterval;
    uint256 public lastExecuted;

    event CheckIntervalUpdated(uint256 checkInterval);

    modifier onlyMultiSig {
        require(msg.sender == multiSig, "Only MultiSig can call");
        _;
    }

    constructor(
        address _multiSig,
        address _facade,
        uint256 _checkInterval
    ) public {
        multiSig = _multiSig;
        facade = _facade;
        checkInterval = _checkInterval;
        lastExecuted = block.timestamp;
    }

    function setCheckInterval(uint256 _checkInterval) public onlyMultiSig {
        checkInterval = _checkInterval;

        emit CheckIntervalUpdated(_checkInterval);
    }

    function check(uint256 _callCost) external view returns (bool canExec, bytes memory execPayload) {
        require((block.timestamp - lastExecuted) > checkInterval, "StrategyResolver::check: Too early to execute action smart contract");

        (bool _canExec, address _strategy) = IStrategyFacade(facade).checkHarvest(_callCost);

        canExec = _canExec;

        execPayload = abi.encodeWithSelector(IStrategyFacade.harvest.selector, address(_strategy));
    }
}
