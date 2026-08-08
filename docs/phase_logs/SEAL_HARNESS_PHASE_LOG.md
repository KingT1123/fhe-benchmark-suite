# SEAL Benchmark Harness — Phase Log

## Goal
Build the **real thesis experiment** harness for SEAL (BFV, CKKS), implementing
the protocol from Chapter 3 (Methodology) — parameter grid, warm-up + 95% CI
statistics, RAPL energy, two scenarios. This is distinct from the earlier
HEProfiler reproduction (`validation/seal/`), which stays as a validation
citation only and contributes no results to this pipeline.

## What was built
- `experiments/config/param_grid.csv` — the N x NIST-category table from
  Chapter 3 Section 3.4, verbatim (chains, log q, depth).
- `experiments/seal/src/bench_seal.cpp` — harness covering keygen, encrypt,
  decrypt, add, multiply, relinearize, for both BFV and CKKS.
- `experiments/seal/CMakeLists.txt` — standard `find_package(SEAL 4.1)` build.
- `experiments/scripts/run_standard.sh` — Scenario A sweep (perf+RAPL, /usr/bin/time).
- `experiments/scripts/run_constrained.sh` — Scenario B sweep (cgroup v2 + taskset,
  Pi 4 ceiling: 4 cores / 4 GB).
- `experiments/scripts/aggregate.py` — the only place statistics are computed
  (warm-up discard, mean/std/95% CI, HIGH_VARIANCE flag at >5% relative std).

## Design decisions worth knowing
- **Compromise index removed.** No column for it anywhere in this pipeline —
  confirmed dropped this session.
- **Fresh ciphertexts every iteration.** Deliberately matches HEProfiler's own
  convention, not the earlier `validation/` harness's convention — this was the
  root cause of the 4x HElib discrepancy found during the HEProfiler
  reproduction. Same choice made here to avoid repeating that mistake.
- **One CLI call = one (scheme, N, category, operation) cell.** Keeps `perf stat`
  energy attribution clean — no risk of one invocation's energy bleeding into
  another operation's numbers.
- **depth==0 configs are skipped, not zero-filled.** `param_grid.csv` says
  N=2048 has depth 0 at every security category (and several other cells at
  higher categories). `multiply`/`relinearize` are architecturally undefined
  there, not "fast" — the harness writes a `skipped_depth0` status row instead
  of silently producing a meaningless number. `aggregate.py` preserves this
  flag all the way into the final CSV (a bug where it didn't was caught and
  fixed during testing today).
- **Simplification, stated openly:** the same depth==0 skip rule is applied to
  BFV even though Chapter 3's own scope note says BFV's noise-budget-based
  depth isn't identical to CKKS's counted-primes depth. This keeps the two
  schemes' grids consistent and comparable; if you want BFV tested at those
  skipped cells too, say so and we'll adjust — it's a one-line condition change.
- **Energy/memory are currently n=1 per config** (one wrapped invocation per
  cell), while latency has full n=100 statistical treatment. Repeating the
  whole wrapped invocation multiple times for an energy CI too was out of
  scope for today; flagged in the final CSV (`n=1_invocation_not_repeated`)
  so this isn't silently overlooked in Chapter 5.

## Verification performed today (in the sandbox, not your machine)
Built Microsoft SEAL v4.1.2 from source (matching your installed version) and
compile-tested + **ran** the harness against the real library before handoff —
not just syntax-checked:

- CKKS, N=8192, category 1 (depth=2), `multiply` — ran cleanly, sane latencies
  (~0.5–0.7 ms).
- CKKS, N=2048, category 1 (depth=0), `multiply` — correctly skipped with the
  documented reason, not a crash or a bogus number.
- BFV, N=8192, category 1, `keygen`, `add` — ran cleanly.
- BFV, N=16384, category 1, `relinearize` — ran cleanly (~26 ms, consistent
  with the larger N).
- CKKS, N=8192, category 1, `encrypt`, `decrypt` — ran cleanly.
- Bad scheme argument (`--scheme=BGV`) — fails with a clear error message
  rather than undefined behaviour (SEAL doesn't implement BGV; that's
  OpenFHE/HElib/Lattigo territory).
- `aggregate.py` run end-to-end against this real output: correctly computed
  mean/std/95% CI, correctly flagged two fast operations as HIGH_VARIANCE
  (expected — this test used only 10–20 reps on a shared 1-core sandbox VM,
  not the production reps=100 on your dedicated machine), and — after a fix —
  correctly preserved the skipped_depth0 flag through to the final CSV.

**Not verified today** (needs your machine, not available in this sandbox):
`perf`/RAPL energy readings, the cgroup v2 constrained scenario, and the full
48-cell sweep (2 schemes x 4 N x 3 categories x 6 ops, minus skips) end-to-end
via the shell scripts. The Python energy/memory log parsing regexes are
written against real `perf stat` and `/usr/bin/time -v` output formats but
could not be exercised against live hardware counters here.

## Update — Docker sweep scripts added
The original `run_standard.sh`/`run_constrained.sh` assumed a bare-machine
SEAL build; you actually have SEAL in Docker (`seal-env`). Replaced with:
- `docker_build_and_run.sh` — builds bench_seal inside the container by
  auto-discovering SEAL's headers/library/deps via `find`, then runs one
  sanity-check config. **Confirmed working on your machine.** Two real path
  bugs were caught and fixed while testing this before sending it (a missing
  include path for SEAL's CMake-generated `config.h`, and a `dirname` depth
  error in computing it) — verified via a full local rebuild-and-run
  simulation in the sandbox, not just re-read.
- `run_standard_docker.sh` / `run_constrained_docker.sh` — full 144-cell
  sweep (12 grid rows x 2 schemes x 6 ops) through Docker. Energy via `perf
  stat` wrapping the host-side `docker run` (RAPL is package-wide, so this
  is correct regardless of the container boundary). Memory via
  `_inner_measure.sh`, a small `/proc/<pid>/status` VmHWM poller that runs
  inside the container — avoids needing to rebuild the image just to add
  GNU `time`.
- Constrained scenario now uses Docker's native `--cpuset-cpus=0-3
  --memory=4g` instead of manual cgroup v2 setup — simpler, no root needed
  beyond normal `docker run` permissions, same Pi 4 ceiling (4 cores/4GB).

Dry-run tested (stubbed `docker`/`perf`) to confirm the sweep loop generates
exactly 144 correctly-formed calls before handing it over.

## Update — First full sweep run on real hardware, bug found and fixed
You ran `run_standard_docker.sh` for real: 122 of 144 configs succeeded on the
first attempt. Two distinct issues in the remaining 22:

**Bug (fixed): CKKS scale was too large for small N.** Root cause, confirmed
by instrumenting SEAL's own source rather than guessing: SEAL's
`total_coeff_modulus_bit_count()` excludes the chain's last prime (reserved
internally for key-switching), so the *usable* data-level budget is smaller
than the nominal sum of prime sizes — e.g. N=4096 category 1's chain
(36+37+36=109 bits nominal) has only 73 usable bits. The harness's fixed
scale of 2^40 fit for one encode (40<73) but not after `multiply()` squares
it (80 >= 73 → SEAL correctly threw `scale out of bounds`). Fixed by
computing the scale dynamically per config from the context's real budget
(`min(40, (total_bits - 10) / 2)` bits), so larger configs keep the original
2^40 (unaffected) and smaller ones scale down safely. Verified: all 7
previously-failing scale-related configs now pass, and 3 previously-passing
configs re-checked with no regression.

**Genuine limitation (not a bug, needs a decision): N=2048, category 5.**
SEAL's own automatic prime search fails outright — "failed to find enough
qualifying primes" — for *every* operation, not just multiply, at this one
(N, category) cell in both BFV and CKKS. There simply aren't enough
NTT-friendly primes of the required tiny bit-length (14-15 bits) distinct
from each other for N=2048. This affects 8 of the 144 cells. Options were:
  (a) document it in Chapter 5 as a finding — the smallest tested ring
      dimension cannot practically support NIST category V security in SEAL,
      independent of the (separately known) depth=0 limitation;
  (b) adjust that one cell's chain in `param_grid.csv` to a feasible nearby
      split (e.g. slightly different bit-sizes) while keeping ~256-bit
      security and depth=0, and re-derive it from HomomorphicEncryption.org's
      table rather than hand-splitting;
  (c) leave it out of the swept grid entirely, noted as an explicit exclusion.

**Decision (resolved): option (a).** Documented as a finding, not patched
around — full writeup at `docs/findings/N2048_CAT5_LIMITATION.md`. The 8
affected cells stay `MISSING` in `seal_standard.csv`, and `param_grid.csv`'s
N=2048/category 5 chain is left exactly as HomomorphicEncryption.org's table
specifies, unmodified. Reasoning: the failure is library-scheme-independent
(reproduces identically for BFV and CKKS), deterministic and driven by
SEAL's own parameter validation rather than any resource limit or tooling
artifact, and reflects a genuine tension between "valid on paper" and
"constructible in practice" at this ring dimension's ~29-bit total modulus
budget. None of the six corpus papers in the literature review surface it,
since none test a ring dimension small enough to hit it — worth noting in
Chapter 5 as a gap in the existing literature's parameter coverage, not just
a limitation of this one library.

## RAPL energy — resolved
`perf stat -e power/energy-pkg/` returned nothing despite the earlier
`kernel.perf_event_paranoid=0` fix. Root cause was as suspected: this is an
AMD machine, and `power/energy-pkg/` is historically an Intel RAPL PMU event
name — the `perf` counter path doesn't work here. **Fix: read
`/sys/class/powercap/intel-rapl:0/energy_uj` directly, bypassing `perf`
entirely.** This works despite the CPU being AMD — the kernel reports AMD's
RAPL-compatible registers through the same `intel-rapl` driver name (see
`CLAUDE.md` env quirks). Needs `sudo` to read. Confirmed working on real
hardware: all 112 successfully-measured configs in `seal_standard.csv` carry
a non-empty `energy_pkg_j_per_op` value. Scenario A's energy column is
trustworthy.

## Update — Scenario B (constrained) sweep run and aggregated
Ran `run_constrained_docker.sh` (4 cores, 4 GB, via Docker's `--cpuset-cpus`/
`--memory`) and `aggregate.py --scenario=constrained`. Same completeness
profile as Standard: 112/144 succeeded, 24 correctly skipped (depth=0), and
the same 8 cells failed (N=2048/category 5, both schemes) — a useful
cross-check, since that failure happens before any benchmarking work starts
(SEAL can't even build the parameter set), so it was expected to be
identical regardless of the resource cap.

**Notable result: constrained numbers are statistically indistinguishable
from Standard — in most cases marginally *lower*, not higher** (e.g.
multiply energy at N=16384: 0.978 J standard vs. 0.801 J constrained; keygen
mean latency: 68.4 ms vs 67.6 ms). Two reasons, both worth stating:

1. **The ceiling itself never binds.** `bench_seal` is a single, largely
   single-threaded process, and its peak memory footprint tops out around
   68 MB even at N=16384 — nowhere near either the 4-core or 4 GB limit.
   There's no resource pressure for the cap to create.
2. **Pinning to 4 fixed cores (`--cpuset-cpus=0-3`) also stopped the OS
   scheduler from migrating the process between cores mid-run, which made
   the timing itself steadier** — not just unthrottled. This shows up in
   the data: `HIGH_VARIANCE` flags dropped from 83 (Standard) to 63
   (Constrained), concentrated in the longer-running depth-dependent ops
   (`multiply` 75%→17% flagged, `relinearize` 83%→50% flagged), while the
   already-near-instant ops (`add`, `decrypt`) stayed flagged almost 100%
   either way — consistent with core-pinning reducing scheduler-migration
   jitter specifically, on top of (not instead of) the inherent
   timer-resolution noise from §8 that no amount of pinning removes.

Worth a sentence in Chapter 5: for SEAL on this hardware, the Pi 4 resource
*ceiling* isn't what would make constrained-device performance worse in
practice — that's presumably the ARM architecture itself, which this
scenario deliberately doesn't reproduce (see the caveat already in
`SEAL_EXPERIMENT_EXPLAINED.md` and Rahman et al.'s own observation that
ARM/x86-64 results aren't directly comparable).

## Update — Edge/Batch scenario built, run, and aggregated
Per Chapter 3: "packs multiple values per ciphertext and measures throughput
on the baseline workstation" — a multi-user/streaming scenario, not IoT,
despite the name. Design decisions (all made explicitly, not defaulted):
(a) runs on full resources like Standard, not the Scenario B ceiling;
(b) batch sizes swept: 1, 10, 100; (c) reps reduced at larger batch sizes
(100/30/10) to keep the sweep tractable, honestly flagged in the data;
(d) keygen measured once per cell (batch-size-invariant), with amortized
cost derived downstream rather than re-measured. Built via
`docker_build_and_run.sh`, smoke-tested at `--batch-size=10` on one config
before committing to the full sweep. `run_edge_batch_docker.sh` writes to
`results/raw/edge_batch/` and `results/logs/edge_batch/` (separate
subdirectories, not the shared `results/raw/` — deliberate, see the script's
own header comment: prevents these files from being silently swept into a
future `aggregate.py --scenario=standard` re-run).

`aggregate.py` gained a `--scenario=edge_batch` mode: computes
`throughput_items_per_sec` per batch size, flags any cell with fewer than
the batch=1 baseline's 100 reps as `reduced_reps_at_batch_size` (same honest
spirit as `n=1_invocation_not_repeated`), and gives keygen its own
`keygen_amortized_ms` rows (derived by dividing the single measured keygen
latency across the swept batch sizes — arithmetic, not a re-measurement,
flagged `derived_not_measured`). Confirmed no regression: re-running
`--scenario=standard` after this change still produces the same 360
rows / 83 HIGH_VARIANCE as before.

**Config counts**: keygen 22/24 cells succeeded (2 failed); the 5 batched
operations (encrypt/decrypt/add/multiply/relinearize × 3 batch sizes) 270/360
succeeded, 72 correctly skipped (depth=0), 18 failed. Every failure and skip
traces to the already-documented N=2048/category 5 finding
(`docs/findings/N2048_CAT5_LIMITATION.md`) — SEAL's prime search fails there
before any benchmarking work starts, so it fails identically across all 3
batch sizes, same root cause, not a new problem.

**Finding 1 — batching doesn't speed up the core operations themselves.**
Comparing throughput at batch=100 vs. batch=1 across all 90
(scheme, N, category, operation) combinations, the ratio is flat: median
0.996x, mean 1.005x (range 0.82x–1.49x, no consistent direction). This
harness's batching means "run the same op B times back-to-back," not "give
SEAL one call that does B items at once" — there's no algorithmic
amortization, so each item costs what it always cost.

**Finding 2 — keygen amortizes exactly as designed.** Amortized keygen cost
drops linearly with batch size: 68.3 ms/item (batch=1) → 6.8 ms/item
(batch=10) → 0.68 ms/item (batch=100). Clean 10x/10x, since this is division,
not a re-measurement.

**Caveat — apparent per-item energy improvement is NOT a genuine drop in the
FHE operation's own energy cost.** Measured per-item `energy_pkg_j_per_op`
dropped substantially at larger batch sizes — all 90 configs lower at
batch=100 than batch=1, median ratio 0.44x. This does not mean the
operation itself got cheaper to compute: RAPL measures energy across the
*entire* Docker invocation (container startup, binary/library loading,
one-time key/context construction), and that fixed per-invocation overhead
gets diluted across more total processed items as batch size grows (more
reps × bigger batch = more items sharing the same fixed startup cost). The
timed *latency* window, by contrast, starts only after setup is complete
(see the isolation convention in bench_seal.cpp), so it doesn't include any
of that overhead — and it's the latency data, not the energy data, that
shows the true per-item cost is flat (Finding 1). Chapter 5 should state
this explicitly as invocation-level fixed-overhead amortization, consistent
with the flat-latency result, not as evidence that batching makes SEAL's
computation itself more energy-efficient.

## Update — Chapter 3's three deferred metrics: `--operation=size` added
Adding storage, noise-budget-evolution, and CKKS-error-accumulation (the
three metrics flagged as "not yet implemented" in
`docs/teaching/FHE_and_SEAL_Concepts_Explained.md`). API confirmed against
the real SEAL 4.1 headers, not from memory: `Ciphertext`/`PublicKey`/
`SecretKey`/`RelinKeys` all expose `save(stream, compr_mode)` returning
exact bytes written; `Decryptor::invariant_noise_budget()` is BFV/BGV-only
(throws for CKKS); CKKS has no SEAL-native noise-budget equivalent, so its
error metric has to come from diffing decrypted output against a
plaintext-computed expected value (Takeshita 2025 precedent). Before
writing any code, verified the local SEAL install used to read those
headers is not just the same version as `seal-env` but byte-identical:
`SEALConfig.cmake` build flags match exactly (4.1.2, Release, ZLIB/ZSTD
on, HEXL off, Blake2xb PRNG) and `diff -rq` against the headers extracted
from the `seal-env` image reported zero differences. Reading local headers
for API lookups is fine; the measurement binary itself is only ever built
and run through `docker_build_and_run.sh` against `seal-env`, same as
every other scenario.

**`--operation=size` implemented and verified end-to-end via Docker.**
Deterministic given a config (no reps/warmup loop, unlike the six timed
operations), so it's a fully separate early-exit code path in `main()`
(`measure_sizes()`) that returns before the timing loop starts — same
shape as the existing `skipped_depth0` branch, and confirmed not to touch
`build_context`/`time_*`/the reps loop (re-ran the existing `multiply`
sanity check after the change: identical output). One row per artifact
(`ciphertext`, `public_key`, `secret_key`, `relin_keys`), serialized with
`compr_mode_type::none` explicitly so the byte count is raw and doesn't
depend on which compression library this SEAL build happened to link.
`relin_keys` gets a `skipped_depth0` row (0 bytes) when `grid.depth == 0`,
matching `build_context`'s own depth-gated relin-key creation — the other
three artifacts are still measured at depth 0, since they don't depend on
it. Verified against real hardware via the Docker pipeline: BFV N=8192
cat=1 (depth>0) measured all 4 artifacts with plausible sizes (relin_keys
largest, ~1.57MB, as expected — it carries multiple key-switching
components); CKKS N=2048 cat=1 (depth=0) measured ciphertext/pk/sk and
correctly skipped relin_keys; N=2048/cat=5 (the documented prime-search
limitation) failed cleanly with the same `ERROR` exit as every other
operation at that cell, no garbage output file.

**`--operation=noise_trace` implemented and verified end-to-end via
Docker.** BFV/BGV only — CKKS gets a clean `skipped_not_applicable_ckks`
row with no context ever built for it (SEAL's `invariant_noise_budget`
throws for CKKS). Unlike every operation above, this one is deliberately
CHAINED (`fresh → 1×add → grid.depth×(multiply→relinearize)`, stopping at
the grid's documented depth, not probing past it) — the isolation
convention protecting per-op timing purity doesn't apply here since this
measures a bit count, not wall-clock. New `run_noise_trace()` function and
a `noise_trace` branch in `main()`, same fully-separate-early-exit shape
as `size`; re-ran the `multiply` sanity check after the change with no
regression. Runs `--trace-reps` trials (default 10, a new CLI flag,
independent of `--reps`/`--warmup` — this is a near-deterministic bit
count, not a noisy wall-clock measurement needing 100 statistical reps).
Keys/context built once per call; only ciphertexts are freshly generated
per step, matching the "fresh ciphertext" convention at the ciphertext
(not key) level.

Verified against real hardware via Docker across four cases: N=8192/cat1
(depth=2) — budget 112→112→80→80→48→48, stays positive through the full
documented depth, security table holds up; N=16384/cat1 (depth=7, the
deepest grid entry) — 312→...→84 across the full 7-round chain, also
stays positive the whole way; CKKS N=8192/cat1 — clean skip, no wasted
context build; N=2048/cat5 — same clean `ERROR` exit as every other
operation at that known-failing cell. **Two real, unplanned observations
from the smoke test, worth flagging for Chapter 5 once the full sweep
runs:** (1) N=2048/cat1 (depth=0) shows noise budget already at exactly
`0` on the **fresh** ciphertext, before any operation at all — depth=0
here isn't merely "insufficient for one more multiply," there's no budget
margin whatsoever from the start; (2) in every depth>0 trace so far,
`relinearize`'s own step never moves the reported bit count at all
(budget identical immediately before and after) — consistent with the
teaching doc's framing that relinearize is structural cleanup rather than
a noise source, now with a real measurement backing it up rather than
just the qualitative claim.

**`--operation=ckks_error` implemented and verified end-to-end via
Docker.** CKKS only — BFV/BGV get a clean `skipped_not_applicable_bfv`
row, no context built (BFV/BGV are exact schemes, no rounding error by
construction). Same chained shape and documented-depth-stopping rule as
`noise_trace` (`fresh → 1×add → grid.depth×(multiply→relinearize)`), plus
one added step per multiply round: `rescale_to_next_inplace`, per the
deliberate divergence agreed beforehand — every timed CKKS operation
elsewhere in this file rescales never, on purpose, to isolate raw per-op
cost (see `build_context()`'s comment), but an unrescaled error trace
would mostly measure how fast an unrescaled scale explodes rather than
real CKKS error accumulation, so this trace rescales for real. Since there
was no existing helper that returns the plaintext vector alongside its
ciphertext (`fresh_ciphertext()` discards it — fine for timing, useless
for diffing), added a dedicated `fresh_ckks_pair()` used only by this
trace; `run_noise_trace`/`time_*`/`build_context` untouched. Each fresh
operand is encoded directly at the running ciphertext's *current*
`parms_id()`/`scale()` (not the top level), so level-tracking after
`rescale` falls out naturally with no explicit `mod_switch_to_inplace`
calls needed. New `run_ckks_error_trace()` function and a `ckks_error`
branch in `main()`, same fully-separate-early-exit shape as `size`/
`noise_trace`; re-ran the `multiply` sanity check after the change with
no regression.

Verified against real hardware via Docker across the same four cases as
`noise_trace`. N=8192/cat1 (depth=2) and N=16384/cat1 (depth=7, the
deepest grid entry) both stay bounded around 1e-8 max-abs-error through
the entire documented chain, never diverging. **N=2048/cat1 (depth=0)
independently cross-validates the `noise_trace` finding from a completely
different measurement path:** error is already O(1) (5.7, 11.8) on the
very first `fresh`/`after_add` steps — the same "no margin at all, not
just insufficient for one more op" conclusion, now confirmed two ways.
BFV skip and N=2048/cat5 failure both behave exactly as `noise_trace`'s
did.

All three of Chapter 3's previously-deferred metrics
(`size`/`noise_trace`/`ckks_error`) are now implemented and Docker-verified.

## Update — Extended-metrics sweep script, subset test, full sweep run
Added `run_extended_metrics_docker.sh`: one Docker call per (scheme, N,
category) cell **per metric** (not per the six timed operations — size/
noise_trace/ckks_error each cover their own artifacts/steps in one call),
no RAPL/peak-memory wrapping (these three aren't latency/energy/memory
measurements). `--trace-reps=10` pinned explicitly in the script for both
`noise_trace` and `ckks_error`, rather than leaving it as bench_seal's
implicit compiled-in default. noise_trace/ckks_error are invoked for BOTH
schemes uniformly on every cell — the scheme-mismatch skip is handled
inside `bench_seal.cpp` itself, so the sweep script needs no branching for
it. Output goes to `results/raw/extended_metrics/` (a subdirectory, not
the shared `results/raw/`), same reasoning as the Edge/Batch scenario:
keeps these out of `aggregate.py --scenario=standard`'s glob.

**Subset test (4 rows spanning depth=0/mid-depth/deepest/known-failure,
before committing to the full grid) caught a real bug**: `--operation=size`
computed its result (which calls `build_context`, throwing at N=2048/cat5)
*before* opening the output file, so failed cells left no file at all —
inconsistent with `noise_trace`/`ckks_error`/the original six operations,
all of which open the file and write the header first, leaving a
header-only file that keeps "attempted and failed" distinguishable from
"never run." Fixed by moving the header-write before the computation;
rebuilt via Docker; re-ran the subset clean (all 24 expected files present,
same 4 genuine errors, all at the documented N=2048/cat5 cell).

**Full sweep run** (12 grid rows x 2 schemes x 3 metrics = 72 calls):
same clean error profile as the subset — exactly 4 `ERROR` exits, all at
N=2048/cat5 (both schemes, `size` and the scheme that actually attempts a
real trace at that cell for `noise_trace`/`ckks_error`), nothing new.
72/72 expected per-cell files present.

Per-cell CSVs consolidated into three master raw files (simple
concatenation — shared header once, then every cell's data rows; NOT
statistics, so this doesn't encroach on `aggregate.py`'s exclusive claim
on that). Consolidation logic lives in the sweep script itself
(`consolidate()`), using a glob (`seal_*_N*_cat*_<suffix>.csv`) that
structurally cannot match its own output filenames on a re-run. Verified
by hand against the grid before trusting the numbers: `noise_budget` =
560 real BFV-trace rows + 12 CKKS skip rows = 572; `ckks_error` = 730 real
CKKS-trace rows + 12 BFV skip rows = 742; `sizes` = 22 successful cells x
4 artifacts = 88 (the 2 failed N=2048/cat5 cells contribute header-only
files, 0 rows). All three match the script's actual output exactly, and
each master file was confirmed to contain exactly one header line, at the
top.

**Final row counts:**
| File | Rows |
|---|---|
| `seal_sizes.csv` | 88 |
| `seal_noise_budget.csv` | 572 |
| `seal_ckks_error.csv` | 742 |

## Update — aggregate.py support for size/noise_trace/ckks_error
Added three new `--scenario=` modes (`size`, `noise_trace`, `ckks_error`),
kept as their own separate aggregation path from
standard/constrained/edge_batch, since none of the three come from a
`--reps`/`--warmup` timed loop, so "statistics" means something different
for each. Reuses the existing final-CSV schema (`library,scheme,N,
category,scenario,operation,metric,mean,std,ci_low,ci_high,flag`) so all
final files stay uniform for later cross-scenario plotting, rather than
inventing a one-off schema per new metric.

- **`size`**: deterministic per (scheme,N,category,artifact) — no trial to
  average, so mean carries the raw byte count and std/ci stay empty,
  explicitly flagged `deterministic_single_measurement` rather than
  silently looking like an unexplained n=1. `relin_keys` at depth==0 gets
  `skipped_depth0_undefined_at_this_config`, same flag text as the other
  scenarios' depth==0 handling.
- **`noise_trace`/`ckks_error`**: group by (scheme,N,category,step_name)
  across the 10 `--trace-reps` trials and compute real mean/std/95% CI per
  step — same statistics policy and same HIGH_VARIANCE (>5% relative std)
  threshold as the six timed operations. `ckks_error` carries two metrics
  per step (`max_abs_error`, `mean_abs_error`), aggregated independently.
  CKKS-N/A rows in `noise_trace` and BFV-N/A rows in `ckks_error` pass
  through as single `skipped_not_applicable_*` rows, not grouped.
- Each reads its already-consolidated master raw file directly
  (`seal_sizes.csv` / `seal_noise_budget.csv` / `seal_ckks_error.csv` from
  `results/raw/extended_metrics/`, written by
  `run_extended_metrics_docker.sh`'s `consolidate()` step), not a per-cell
  glob — that consolidation already happened once, upstream, by design.

Ran all three against the full-sweep data; row counts (88 / 68 / 170)
verified by hand against the grid before trusting them (e.g.
`noise_budget`: 56 distinct BFV step-groups across 11 successful cells +
12 CKKS skip rows = 68). One real, explainable pattern surfaced in the
`ckks_error` HIGH_VARIANCE flagging: **all 73 flags land on
`max_abs_error`, none on `mean_abs_error`** — `max` is a single
worst-slot statistic (volatile trial-to-trial), while `mean` averages
across thousands of slots per trial, smoothing the same underlying noise
— the error-metric analogue of the existing latency finding that fast,
noise-sensitive operations (`add`) flag far more often than stable ones
(`keygen`). `noise_trace` flagged exactly once, at BFV N=2048/cat3
(`after_add`, mean 5.9 bits, std 0.32 — a genuinely thin-budget cell where
a ±1-bit fluctuation is large in relative terms, correctly caught rather
than spuriously flagged).

All three of Chapter 3's previously-deferred metrics are now fully closed:
implemented, Docker-verified, swept across the full grid, and aggregated
into `results/final/`.

## Next steps
1. ~~Decide the N=2048/category 5 question above (a/b/c).~~ **Resolved** —
   see decision above and `docs/findings/N2048_CAT5_LIMITATION.md`.
2. ~~Get RAPL working (see diagnostic commands from Claude) or accept
   Scenario A's energy column stays empty for now.~~ **Resolved** — direct
   `/sys/class/powercap/` read, see above.
3. ~~Re-run `run_standard_docker.sh` with the fixed binary — the 22
   previously failing configs should now mostly succeed (all but the 8 in
   the N=2048/category 5 cell, which stay excluded per the resolved
   decision above).~~ **Done** — 112/144 succeeded, 24 correctly skipped
   (depth=0), 8 excluded and documented (N=2048/cat5 finding).
4. ~~`aggregate.py --scenario=standard`, sanity-check a few numbers against
   the validation/ HEProfiler reproduction.~~ **Done** — `seal_standard.csv`
   is the current final output. Scenario A (Standard) is fully closed, no
   open technical items remain.
5. ~~Do Scenario B (`run_constrained_docker.sh`) — script exists, not yet
   run.~~ **Done** — see update above. Scenario B is fully closed too, same
   completeness profile as Scenario A.
6. ~~Build Edge/Batch scenario support and run it.~~ **Done** — see update
   above. All three SEAL scenarios (Standard, Resource-constrained,
   Edge/Batch) are now fully closed.
7. Same harness pattern repeats for OpenFHE, HElib, Lattigo.
8. ~~`size`/`noise_trace`/`ckks_error`: implement, sweep, and aggregate.~~
   **Done** — see updates above. Implemented, Docker-verified, full
   72-call sweep run (`seal_sizes.csv` 88 raw rows,
   `seal_noise_budget.csv` 572, `seal_ckks_error.csv` 742), and all three
   `aggregate.py` modes written and run (`results/final/seal_sizes.csv`
   88 rows, `seal_noise_budget.csv` 68 rows, `seal_ckks_error.csv` 170
   rows). All three of Chapter 3's previously-deferred metrics are now
   fully closed for SEAL.
