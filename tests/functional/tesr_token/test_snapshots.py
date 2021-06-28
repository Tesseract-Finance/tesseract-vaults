import pytest
import brownie


@pytest.fixture
def tesr(gov, TesrToken):
    yield gov.deploy(TesrToken, "TESR Token", "TESR", 18)


token_supply = 450000000e18


def test_snapshot_revert(tesr, gov):
    with brownie.reverts("Invalid Snapshot Id"):
        tesr.balance_of_at(gov, 0)

    tesr.snapshot()

    with brownie.reverts("Invalid Snapshot Id"):
        tesr.total_supply_at(1)


def test_snapshots_when_mint(tesr, gov, minter):
    assert tesr.balanceOf(gov) == token_supply
    tesr.set_minter(minter, {"from": gov})
    amount_to_burn = 1000e18
    amount_to_mint = 20e18
    tesr.burn(amount_to_burn, {"from": gov})

    tesr.mint(gov, amount_to_mint, {"from": minter})
    tesr.snapshot()

    assert (
        tesr.total_supply_at.call(0) == token_supply - amount_to_burn + amount_to_mint
    )

    tesr.mint(gov, amount_to_mint, {"from": minter})
    tesr.snapshot()

    assert tesr.total_supply_at.call(1) == token_supply - amount_to_burn + (
        2 * amount_to_mint
    )


def test_snapshots_when_burn(tesr, gov):
    assert tesr.balanceOf(gov) == token_supply
    amount_to_burn = 1e18
    tesr.burn(amount_to_burn)

    tesr.snapshot()

    tesr.burn(amount_to_burn)
    assert tesr.totalSupply() == token_supply - (2 * amount_to_burn)
    assert tesr.total_supply_at.call(0) == token_supply - amount_to_burn
    assert tesr.balance_of_at.call(gov, 0) == token_supply - amount_to_burn

    tesr.snapshot()

    assert tesr.total_supply_at.call(1) == token_supply - (2 * amount_to_burn)
    assert tesr.balance_of_at.call(gov, 1) == token_supply - (2 * amount_to_burn)


def test_snapshots_when_transfer(tesr, gov, rando):
    assert tesr.balanceOf(gov) == token_supply
    assert tesr.balanceOf(rando) == 0

    amount_to_transfer = 1e18
    tesr.transfer(rando, amount_to_transfer, {"from": gov})

    tesr.snapshot()

    assert tesr.total_supply_at.call(0) == token_supply
    assert tesr.balance_of_at.call(gov, 0) == token_supply - amount_to_transfer
    assert tesr.balance_of_at.call(rando, 0) == amount_to_transfer

    tesr.transfer(gov, amount_to_transfer / 2, {"from": rando})

    tesr.snapshot()

    assert tesr.balance_of_at.call(gov, 1) == token_supply - amount_to_transfer + (
        amount_to_transfer / 2
    )
    assert tesr.balance_of_at.call(rando, 1) == amount_to_transfer - (
        amount_to_transfer / 2
    )
