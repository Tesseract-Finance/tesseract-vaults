import pytest
import brownie
from brownie import ZERO_ADDRESS


@pytest.fixture
def tesr(gov, TesrToken):
    yield gov.deploy(TesrToken, "TESR Token", "TESR", 18)


token_supply = 450000000e18


def test_allowance(tesr, gov, rando):
    assert tesr.balanceOf(gov) == token_supply

    amount_to_approve = 1e18
    tesr.approve(rando, amount_to_approve, {"from": gov})

    assert tesr.allowance(gov, rando) == amount_to_approve

    with brownie.reverts():
        tesr.approve(rando, amount_to_approve, {"from": gov})


def test_transfer(tesr, gov, rando):
    assert tesr.balanceOf(gov) == token_supply
    assert tesr.balanceOf(rando) == 0
    amount_to_transfer = 1e18

    with brownie.reverts():
        tesr.transfer(ZERO_ADDRESS, amount_to_transfer, {"from": gov})

    tesr.transfer(rando, amount_to_transfer, {"from": gov})
    assert tesr.balanceOf(rando) == amount_to_transfer
    assert tesr.balanceOf(gov) == token_supply - amount_to_transfer


def test_transfer_from(tesr, gov, rando, keeper):
    assert tesr.balanceOf(gov) == token_supply
    assert tesr.balanceOf(rando) == 0
    amount_to_transfer = 1e18

    tesr.approve(keeper, amount_to_transfer, {"from": gov})

    with brownie.reverts():
        tesr.transferFrom(gov, ZERO_ADDRESS, amount_to_transfer, {"from": keeper})

    tesr.transferFrom(gov, rando, amount_to_transfer, {"from": keeper})
    assert tesr.balanceOf(rando) == amount_to_transfer
    assert tesr.balanceOf(gov) == token_supply - amount_to_transfer
