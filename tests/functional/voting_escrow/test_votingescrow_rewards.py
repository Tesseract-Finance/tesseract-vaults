import pytest
import brownie


def test_set_rewards_contract(voting_escrow, accounts):
    with brownie.reverts("dev: admin only"):
        voting_escrow.set_rewards_contract(accounts[1], {"from": accounts[1]})


def test_set_rewards_contract(voting_escrow, accounts):
    voting_escrow.set_rewards_contract(accounts[1], {"from": accounts[0]})

    assert voting_escrow.rewards_contract() == accounts[1]
