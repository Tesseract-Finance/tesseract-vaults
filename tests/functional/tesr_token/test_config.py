import pytest
import brownie
from brownie import ZERO_ADDRESS

token_name = "TESR Token"
token_symbol = "TESR"
token_decimals = 18
token_supply = 450000000e18


@pytest.fixture
def tesr(gov, TesrToken):
    yield gov.deploy(TesrToken, token_name, token_symbol, token_decimals)


def test_deploy(tesr):
    assert tesr.name() == token_name
    assert tesr.symbol() == token_symbol
    assert tesr.decimals() == token_decimals
    assert tesr.totalSupply() == token_supply


def test_set_admin(tesr, gov, rando):
    multisigDao = rando
    assert tesr.admin() == gov

    tesr.set_admin(multisigDao)
    assert tesr.admin() == multisigDao


def test_set_minter(tesr, gov, minter, rando):
    assert tesr.admin() == gov
    assert tesr.minter() == ZERO_ADDRESS

    # admin only
    with brownie.reverts():
        tesr.set_minter(minter, {"from": rando})

    tesr.set_minter(minter, {"from": gov})
    assert tesr.minter() == minter

    # can set the minter only once, at creation
    with brownie.reverts():
        tesr.set_minter(minter, {"from": gov})


def test_set_name(tesr, gov, rando):
    new_name = "New Token Name"
    new_symbol = "NTS"

    with brownie.reverts("Only admin is allowed to change name"):
        tesr.set_name(new_name, new_symbol, {"from": rando})

    tesr.set_name(new_name, new_symbol, {"from": gov})

    assert tesr.name() == new_name
    assert tesr.symbol() == new_symbol
