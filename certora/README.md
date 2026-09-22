# AutoProver rules for RoycoDayAccountant

These Certora Prover artifacts were generated for `src/accountant/RoycoDayAccountant.sol`.

## Source inputs

- Design: `ARCHITECTURE.md`
- Threat model: `AUTOPROVER.md`

## Generated files

- `certora/specs/autospec_Capacity_Math.spec`
- `certora/specs/autospec_Parameter_Governance.spec`
- `certora/specs/invariants.spec`
- `certora/specs/summaries/custom_summaries.spec`
- `certora/specs/summaries/EIP712.spec`
- `certora/specs/summaries/FixedPointMathLib.spec`
- `certora/specs/summaries/Math.spec`
- `certora/specs/summaries/OpenZeppelin/OZ_Math-RoycoDayAccountant.spec`
- `certora/specs/summaries/OpenZeppelin/OZ_SafeERC20.spec`
- `certora/specs/summaries/OpenZeppelin/OZ_ShortStrings.spec`
- `certora/specs/summaries/OpenZeppelin/OZ_Strings.spec`
- `certora/specs/summaries/RoycoDayAccountant_base_summaries.spec`
- `certora/specs/summaries/RoycoDayAccountant_call_resolution.spec`
- `certora/specs/summaries/Strings.spec`
- `certora/confs/autospec_Capacity_Math.conf`
- `certora/confs/autospec_Parameter_Governance.conf`
- `certora/mocks/DummyERC20Impl.sol`

## Run the rules

How to run Certora Prover:

1. Install the Certora Prover CLI and export your API key:

```bash
pip install certora-cli
export CERTORAKEY=<your-certora-api-key>
```

2. From the repository root, run the generated configs:

```bash
certoraRun certora/confs/autospec_Capacity_Math.conf
certoraRun certora/confs/autospec_Parameter_Governance.conf
```

The generated configs expect these Solidity compilers on your PATH: `solc-0.8.35` (installable with `solc-select`).

Note: `certoraRun` uploads the repository to Certora's cloud for verification.

Full setup and usage documentation: https://docs.certora.com/en/latest/
