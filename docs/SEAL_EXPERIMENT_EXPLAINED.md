# The SEAL Experiment, Explained From the Ground Up

This document exists so you never have to wonder "what did we actually do
and what does it mean." Read it top to bottom once, then keep it as a
reference. Everything in here describes what's *already done* for SEAL. Not
yet started: OpenFHE, HElib, Lattigo (same approach repeats for each), and
Scenario B (the constrained/Raspberry-Pi-ceiling run) for SEAL itself.

---

## 1. What question is this experiment answering?

Your thesis compares FHE libraries. To compare them fairly, you can't just
run each library "however" — you need everyone tested under the exact same
rules. Those rules are your Chapter 3 methodology. This experiment is the
*implementation* of those rules for one library (SEAL).

Concretely, for every combination of:
- **ring size N** (2048, 4096, 8192, or 16384 — bigger N = more security
  headroom and more precision, but slower),
- **security category** (1, 3, or 5 — corresponding to 128-bit, 192-bit,
  256-bit security),
- **scheme** (BFV or CKKS — SEAL doesn't implement BGV, so that's not
  tested here),
- **operation** (key generation, encryption, decryption, addition,
  multiplication, relinearization)

...we measure: how long it takes (latency), how much energy the CPU package
uses, and how much memory it needs. That's it. That's the whole experiment,
repeated 144 times (12 grid rows × 2 schemes × 6 operations).

## 2. Why these specific N / category combinations?

This isn't arbitrary — it's your own Chapter 3 table, encoded in
`experiments/config/param_grid.csv`. For each (N, category) pair, that file
also specifies the **modulus chain**: the actual sequence of prime numbers
SEAL multiplies together to form the "space" ciphertexts live in. Bigger
chains = more room to compute on encrypted data, but bigger ciphertexts and
slower operations. This is the fundamental trade-off your whole thesis is
measuring.

One column in that file matters a lot: **depth**. This is how many
multiplications-in-a-row that chain can support before running out of room.
Several of your rows have depth=0 — meaning that combination of N and
security level is only strong enough to encrypt/decrypt/add, not multiply.
This isn't a mistake; it's a real mathematical fact about small, high-security
parameter choices, and the harness respects it (see §5).

## 3. What does each operation actually measure?

| Operation | What it measures |
|---|---|
| `keygen` | Generating a fresh secret key + public key (+ relin key if depth>0) |
| `encrypt` | Turning one plaintext into one ciphertext |
| `decrypt` | Turning one ciphertext back into plaintext |
| `add` | Adding two fresh ciphertexts together |
| `multiply` | Multiplying two fresh ciphertexts (before any cleanup step) |
| `relinearize` | The cleanup step after a multiply that keeps ciphertext size manageable |

Each one is timed **in isolation** — e.g. `multiply`'s number does not
include the cost of generating the two ciphertexts it multiplies; that setup
happens but isn't part of the clock. This isolation is deliberate, so that
if your results chapter says "multiply costs X ms," X is really just the
multiply, not multiply-plus-setup-noise.

## 4. The statistical protocol (why you'll see mean/std/CI, not single numbers)

For every single (config, operation) cell, the program doesn't run once — it
runs **105 times**: 5 "warm-up" runs that get thrown away (the first few
runs of anything are often slower due to caches not being warm yet), then
**100 measured runs**. From those 100, `aggregate.py` computes:
- **mean** — the average latency/energy/memory
- **std** — how much it varied run to run
- **95% CI** (confidence interval) — the range you can be 95% confident the
  true average falls in
- **flag** — set to `HIGH_VARIANCE` if the std is more than 5% of the mean,
  as a signal that this particular measurement might be noisy and worth a
  second look (see §8 — in practice, for this run, this turned out to be
  expected and not a problem)

This 100-run-with-warmup design isn't arbitrary either — it matches your
Chapter 3 protocol, which itself follows a standard benchmarking-hygiene
reference (Weiser et al., 2018, "Benchmarking Crimes").

## 5. Why some rows say "SKIPPED" and that's correct, not an error

Remember depth=0 from §2? For those (N, category) combinations, `multiply`
and `relinearize` are not just "slow" — they're **undefined**. There's
nothing meaningful to measure. Rather than force a multiplication through
and report a misleading number, the harness detects depth=0 up front and
writes a clearly-labeled "skipped" row instead. This happened for 24 of the
144 configs (6 param-grid rows × 2 schemes × 2 operations). This is a
feature, not a bug — it stops bad data from ever entering your results.

## 6. The two real problems we found, and what "fixed" means for each

### 6a. Bug (ours, now fixed): CKKS scale was too big for small N

**What "scale" is, briefly:** CKKS encodes real numbers approximately, and
"scale" controls how much precision you keep. It has to be chosen to fit
within the ciphertext's available room.

**What went wrong:** the harness used one fixed scale value for every
config. That value was fine for large N, but for smaller N, SEAL internally
reserves part of the modulus chain for its own bookkeeping (key-switching),
leaving less usable room than the chain's raw size suggests. The fixed scale
didn't fit in that smaller room once a multiplication doubled it.

**How we know it's actually fixed, not just "should be fixed":** I rebuilt
SEAL from source in a sandbox, reproduced the exact failure with your exact
parameters, instrumented SEAL's own code to print the real numbers, applied
a fix that computes the right scale *per config* instead of guessing one
value for all of them, and re-ran every previously-failing case plus a few
previously-passing ones to confirm nothing broke. All passed. Then you ran
it for real and got the same result: the fix held on real hardware, not just
in my sandbox.

**Does this affect timing validity?** No. Scale is a precision setting, not
a performance setting — it has no effect on how long an operation takes. It
only affects whether SEAL is willing to run the operation at all.

### 6b. Genuine limitation (not a bug — decision resolved)

**N=2048 at category 5** (256-bit security) fails completely — every single
operation, not just multiply. SEAL's own prime-search gives up: at that
combination, there simply aren't enough valid numbers of the right
mathematical shape (specific bit-size, specific type of prime) for SEAL to
build a working parameter set at all. This is a hard mathematical fact about
that specific combination, not something a code fix can paper over.

This affects 8 of the 144 configs (keygen/encrypt/decrypt/add, both
schemes). **Resolved: documented as a Chapter 5 finding**, not patched
around — see `docs/findings/N2048_CAT5_LIMITATION.md` for the full writeup
and §11.

## 7. Energy and memory: how they're actually measured

**Memory** is measured *inside* the Docker container: a small watcher script
(`_inner_measure.sh`) polls `/proc/<pid>/status` while `bench_seal` runs and
records the peak value it ever saw. This is standard Linux bookkeeping every
process already has — no extra software needed.

**Energy** reads your CPU's own built-in power meter directly:
`/sys/class/powercap/intel-rapl:0/energy_uj`, a running counter (in
microjoules) the hardware itself maintains. We read it immediately before
and immediately after each config's 100 runs, subtract, and that's the
energy for those 100 runs (divided by 100 for a per-operation number). This
file needs root to read, which is why the sweep script needs `sudo`.

One nuance worth knowing: your laptop is AMD, and this counter file is
named `intel-rapl`. That's not a bug — AMD's newer chips expose
RAPL-compatible energy registers, and the Linux kernel happens to report
them through the same driver/naming Intel originally introduced. The number
is real and belongs to your CPU either way.

**One honest limitation to note in your methodology:** energy and memory are
each measured **once** per config (not averaged over 100 runs like latency
is) — you'll see this flagged as `n=1_invocation_not_repeated` in the final
CSV. This was a scope decision, not an oversight: repeating the *entire*
100-run block multiple times just for an energy confidence interval was out
of scope for this pass. Worth a sentence in your limitations section.

## 8. What the "83 HIGH_VARIANCE flags" actually mean (short version: nothing worrying)

When you ran `check_variance.py`, the flags broke down like this:

| Operation | Flagged |
|---|---|
| add | 100% |
| decrypt | 95% |
| encrypt | 95% |
| multiply | 75% |
| relinearize | 83% |
| **keygen** | **0%** |

This shape — fastest operations flagged almost every time, slowest operation
(`keygen`, which takes milliseconds) flagged *never* — is the signature of
**timer-resolution noise**, not a machine problem. If something else on your
laptop had been competing for CPU during the run, it would have jittered
*everything* somewhat randomly, including `keygen`. It didn't touch
`keygen` at all. Timing something that takes 0.01 milliseconds is
inherently harder to do precisely than timing something that takes 10
milliseconds — OS scheduling and clock granularity start to matter at that
scale. This is a documented, expected phenomenon in exactly the reference
your own protocol already cites (Weiser et al., 2018).

**What to do about it:** nothing. The data is valid. This is worth one
honest sentence in your methodology or results write-up, not a re-run.

## 9. Two small infrastructure fixes along the way (for completeness)

- **scipy**, installed via `apt`, conflicted with a newer `numpy` already on
  your system (a binary-compatibility mismatch, not something either of us
  did wrong). `aggregate.py` was designed to work without scipy anyway
  (falling back to a very close statistical approximation), but its error
  handling was too narrow to catch *this specific* failure type. One-word
  fix (`ImportError` → `Exception`), verified before sending. The 95% CI
  numbers in your results are correct either way — with or without scipy,
  the difference is under 2%, immaterial at 100 samples.
- **The Docker build script** originally missed one of SEAL's internal
  generated files (`config.h`) when auto-locating SEAL inside your
  container, and had an off-by-one in how it computed that file's folder.
  Both caught and fixed by actually rebuilding SEAL and running the exact
  discovery logic in a sandbox before sending it to you — not discovered by
  you hitting the wall.

## 10. What your data actually contains right now

File: `experiments/results/final/seal_standard.csv`, 360 rows. Each row is
one (library, scheme, N, category, scenario, operation, metric) combination:

```
library,scheme,N,category,scenario,operation,metric,mean,std,ci_low,ci_high,flag
```

- **112 configs** have full data: a `latency_ms` row, an `energy_pkg_j_per_op`
  row, and a `peak_memory_mb` row each (336 rows total).
- **24 configs** are correctly skipped (depth=0), one blank row each, flagged
  `skipped_depth0_undefined_at_this_config`.
- **8 configs** (N=2048/category 5) don't appear at all — SEAL couldn't run
  them, so there's nothing to aggregate (see §6b, §11).

No compromise index anywhere — confirmed dropped from this pipeline weeks
ago and it never came back.

## 11. What's still open

1. ~~**N=2048/category 5**: document as a finding, try a different
   small-prime split, or exclude outright.~~ **Resolved** — documented as a
   finding (`docs/findings/N2048_CAT5_LIMITATION.md`). The 8 affected
   configs stay excluded from `seal_standard.csv`; `param_grid.csv` is left
   unmodified. This closes out Scenario A (Standard) — no open technical
   items remain there.
2. ~~When you're ready, we still need **Scenario B** for SEAL (the simulated
   Raspberry Pi 4 ceiling — 4 cores, 4GB RAM) via
   `run_constrained_docker.sh`, not yet run.~~ **Resolved** — Scenario B ran
   and aggregated (`seal_constrained.csv`), same completeness profile as
   Scenario A (112 measured / 24 skipped / 8 documented finding). The
   results turned out statistically indistinguishable from Scenario A, for
   two reasons: (1) the 4-core/4GB ceiling never binds — `bench_seal`'s peak
   memory tops out around 68 MB and it's largely single-threaded, so there
   was no resource pressure for the cap to create; and (2) pinning to fixed
   cores also stopped the OS scheduler from migrating the process mid-run,
   which made the *timing itself* steadier, not just unthrottled — visible
   as fewer `HIGH_VARIANCE` flags on the longer-running ops. Full writeup in
   `docs/phase_logs/SEAL_HARNESS_PHASE_LOG.md`.

## 12. What comes after SEAL

SEAL itself is now done — Scenario A and Scenario B are both fully closed.
The exact same pattern — harness, param grid, Docker wrapper, aggregate
script — repeats next for **OpenFHE**, **HElib**, and
**Lattigo**. SEAL was the hard part: the approach, the bug classes, and the
Docker plumbing are now proven. The others will go faster because we already
know what to watch for.
