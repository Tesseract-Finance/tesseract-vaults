from brownie import StrategyGenLevAAVE


def main():
    source = StrategyGenLevAAVE.get_verification_info()["flattened_source"]

    with open("flat.sol", "w") as f:
        f.write(source)
