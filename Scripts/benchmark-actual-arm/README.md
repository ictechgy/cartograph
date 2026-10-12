# One-state runtime correctness validation

This is a bounded correctness diagnostic, with one fixed baseline/Cartograph pair on the already restored
mixed-iOS compiler generation. It reuses the single existing psutil installation and records the complete
outer worker cost. It exports no performance ratio or superiority result.

See [the execution and failure contract](INTEGRATION-BOUNDARIES.md),
[the prospective installer amendment](INSTALLER-REVIEW.md), and
[exact copied-source provenance](COPIED-PROVENANCE.json). Historical original/successor scripts are
explicit test fixtures; production selects the reviewed files named by the controller.

Run the offline controls from the repository root:

```sh
python3 -m unittest discover -s Scripts/benchmark-actual-arm -p 'test_*.py' -v
python3 -m unittest discover -s Scripts/benchmark-actual-arm/runtime -p 'test_*.py' -v
python3 Scripts/verify-native-measurement-contract.py
```

Only normalized safe evidence is uploaded. SDK content acceptance, real-arm observer calibration,
independent holdouts and final paired performance sessions remain separate gates.
