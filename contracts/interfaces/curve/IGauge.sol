// SPDX-License-Identifier: GNU Affero

pragma solidity ^0.6.12;

interface IGauge {
    function balanceOf(address _addr) external view returns (uint256);
    function claimable_rewards(address _addr, address _token) external view returns (uint256);

    function claimable_reward_write(address _addr, address _token) external returns (uint256);

    function deposit(uint256 _value) external; // _addr=msg.sender, False
    function deposit(uint256 _value, address _addr) external; // False
    function deposit(
        uint256 _value,
        address _addr,
        bool _claim_rewards
    ) external;
    function withdraw(uint256 _value) external; // _claim_rewards=False
    function withdraw(uint256 _value, bool _claim_rewards) external;

    function claim_rewards() external; // owner=msg.sender, receiver=ZERO_ADDR
    function claim_rewards(address _owner) external; // receiver=ZERO_ADDR
    function claim_rewards(address _owner, address _receiver) external;
    function set_rewards_receiver(address _receiver) external;
}
