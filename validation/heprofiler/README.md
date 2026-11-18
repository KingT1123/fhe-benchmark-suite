# HEProfiler reproduction (validation only)

Before the thesis harnesses were written, the CKKS benchmarks of HEProfiler
(Takeshita et al., J. Cryptographic Engineering 15(2), 2025) were reproduced on
this laptop (AMD Ryzen 9 6900HX), with the paper's parameters (depths 1-18,
N = 2^13 / 2^14 / 2^15, 128-bit security, scale 2^40, inputs 1.0,
50 iterations). The paper's machine was an Intel Xeon Gold 6226. This is a
check of the tools and contributes no thesis result.

Files (copied from the reproduction workspace, May-June 2026):

| File | Content |
|---|---|
| `seal_comparison.csv` | SEAL 4.1.2: the paper's published value (columns without prefix) and this laptop's (`our_*`) per depth; latency in ms, ciphertext size in MB. Error columns: the paper's are a fraction, `our_*_err` are a percentage. |
| `helib_paper_multiplication.csv` | HElib: the paper's published multiplication latency per depth (ms), extracted from the paper's released data (`Final_data/avx2/SHE_tests/Depth/report.csv`). |
| `helib_heprofiler_code_report.csv` | HElib: HEProfiler's own code run on this laptop, its report format (per operation: mean and standard deviation, ns; depths 1-15). |
| `helib_own_harness_multiplication.csv` | HElib: the first, own reproduction program (mean latency per depth, ms). It reused the same two input ciphertexts in every iteration. |

Summary: `cd experiments/scripts; python3 aggregate.py --scenario=heprofiler_validation`
writes `experiments/results/final/heprofiler_validation_{seal,helib}.csv`.
