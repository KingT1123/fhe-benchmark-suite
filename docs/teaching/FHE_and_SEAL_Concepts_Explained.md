# FHE and the SEAL Experiment, Explained in Plain Language

**Purpose of this document:** a self-contained walkthrough of every concept behind the SEAL benchmarking work — written so it can be read start to finish by someone with no cryptography background, and used as a reference when explaining the thesis to others (defense, committee, a curious friend).

**Companion visual:** `noise_budget_explained.svg` — a diagram of the noise budget shrinking with operations, and of why higher security shrinks it further at the same ring dimension. Reference it alongside Phase 2 below.

---

## Quick Summary (for a 2-minute explanation)

We measure how expensive it is to compute on **encrypted** data using the SEAL library, without ever decrypting it. "Expensive" is measured three ways — time (latency), electricity (energy), and RAM (memory) — across three realistic situations: an unrestricted machine (Standard), a resource-capped machine simulating a small device (Constrained), and a continuous stream of requests (Edge/Batch). The headline findings: SEAL's cost rises predictably with security level and with ring size; it comfortably survives the resource cap; and batching only helps the one-time key-setup cost, not the recurring cost of each operation.

---

## Phase 1 — The Big Picture, and the Three Schemes

**The problem FHE solves.** Normal encryption is a locked box — nobody can touch what's inside without the key, which means nobody can *compute* on it either without first decrypting it, exposing it in the process. Fully Homomorphic Encryption (FHE), made possible by Craig Gentry in 2009, changes this: imagine a locked box with gloves built into the sides. A worker can reach in and manipulate the contents — combine, process, rearrange — without ever opening the box. Only the owner, with the real key, opens it afterward and finds the correct computed result. **A server can compute on your data without ever seeing it.**

**Why three schemes, not one.** After Gentry's breakthrough, two practical families emerged:
- **BFV** (2012) and **BGV** (2012) — work with **exact whole numbers**. Encrypt 7 and 3, add, decrypt: exactly 10. Used where correctness must be perfect (counting, financial totals, database lookups).
- **CKKS** (2017) — works with **approximate real numbers (decimals)**. Encrypt 7.2 and 3.1, add, decrypt: something very close to 10.3, not necessarily bit-exact. In exchange, CKKS is much better suited to machine learning and statistics, where small rounding error is already normal.

There is no single "best" scheme — they're built for different jobs. This is why the thesis tests more than one scheme per library.

---

## Phase 2 — The Vocabulary of a Parameter Set

**Noise — the hidden cost of security.** Every encryption deliberately mixes in a small amount of random "static" — this is where the security comes from (like a real signal buried in radio static; without the key, an attacker can't separate the two). Every operation adds a little more static. Addition adds barely any; multiplication adds a lot. If too much accumulates, decryption returns garbage instead of the correct answer.

**Noise budget.** The ceiling on how much computing can happen before the static drowns out the real answer. Example progression (BFV, illustrative numbers from a real slide):

| Stage | Budget (bits) | Status |
|---|---|---|
| Fresh ciphertext | 100 | ✓ |
| After 5 additions | 95 | ✓ |
| After 1 multiplication | 60 | ✓ |
| After 2 multiplications | 20 | ⚠ risky |
| After 3 multiplications | 0 | ✗ FAIL |

Addition barely touches the budget. Multiplication roughly halves it each time.

**Ring dimension (N)** — the size of the "box." Bigger N = more noise budget and more SIMD "slots" to pack values into, but slower to move around. This is why larger N is consistently slower across every test.

**Modulus (q)** — the ciphertext modulus: every number inside a ciphertext lives between 0 and q−1, wrapping around like a clock face ("mod q"). Built by multiplying several primes together (the "modulus chain" in `param_grid.csv`). $\log_2 q$ is exactly the "budget" number reported throughout the results.

**Multiplicative depth** — how many multiplications in a row a parameter set can survive before the budget hits zero. `depth = 0` means the budget is too thin to survive even one multiplication — this is why `multiply`/`relinearize` are correctly *skipped*, not measured badly, at those rows.

**Security level (category 1 / 3 / 5)** — how hard the encryption is to break without the key. Category 1 ≈ 128-bit, category 3 ≈ 192-bit, category 5 ≈ 256-bit — each step is an enormously harder lock, mapped via the NIST post-quantum security categories.

**The counter-intuitive core relationship: why q shrinks as the security category rises, at the same N.** Security here doesn't come from q being large in absolute terms — it comes from the *ratio* between N and q (the underlying hard problem is called RLWE). A bigger q, on the same N, gives an attacker more "slack" to be only approximately right and still succeed via lattice-based attacks — so a bigger q actually weakens security at fixed N, not strengthens it. To make the lock harder while keeping the same N, the only lever available is shrinking q — and since the noise budget *is* $\log_2 q$, that directly shrinks the budget. Real proof, from the thesis's own parameter grid, at N = 8192:

| Security category | log₂(q) | Resulting depth |
|---|---|---|
| Category 1 — 128-bit | 200 | 2 (usable) |
| Category 3 — 192-bit | 152 | 1 |
| Category 5 — 256-bit | 118 | 0 (no multiply possible) |

These exact numbers come from real, published attack-simulation tables (the Homomorphic Encryption Standard, 2021) — not a formula computed by hand.

---

## Phase 3 — The Six Operations

- **Keygen** — produces the **secret key** (never shared), the **public key** (safe to share, used only for encrypting), and — only when depth > 0 — the **relinearization key** (a cleanup helper, explained below).
- **Encrypt** — locks real data using the public key; this is where a ciphertext's noise first gets introduced.
- **Decrypt** — unlocks a ciphertext using the secret key, provided the noise budget never hit zero.
- **Add** — cheap; barely touches the noise budget. Consistently the fastest operation measured.
- **Multiply** — expensive, and structurally different. A ciphertext is a *pair* of polynomials $(A, B)$. Multiplying two ciphertexts is like multiplying two two-term algebra expressions $(a+b)(c+d)$ — it produces a **three-part result**, not the usual two-part shape. This is why multiply is consistently the slowest operation, and why it burns through the noise budget fastest.
- **Relinearize** — the required cleanup after multiply: squeezes that three-part result back down to the normal two-part shape, using the relinearization key. Measured as a separate step because it is genuinely separate work — the math, then the cleanup.

**What keygen mathematically produces:**
- Secret key $s$: a string of small random values (−1, 0, or 1), repeated N times. Small-and-random is what the security proof relies on.
- Public key: a random polynomial $a$ paired with $b = -a\cdot s + e$ (e = fresh noise). To anyone without $s$, this pair looks like pure noise — but it's algebraically tied to $s$ in a way that makes encryption work.
- Relinearization key: the same disguising trick, applied to $s^2$ instead of $s$ — exactly what's needed to undo multiply's three-part result.

**Where the encrypted numbers come from.** Freshly, randomly generated every single iteration (0/1 values for BFV, random decimals for CKKS) — never reused. The generator's starting point is fixed, so results are reproducible run-to-run, but the values themselves are genuinely different each iteration.

**What the test actually measures — precisely.** For every operation, the sequence is: generate needed ciphertext(s) (untimed) → start the clock → run only the one operation being tested → stop the clock. **Decryption of the result to check correctness never happens as part of a timed measurement.** This is deliberate: the test measures *cost*, not *correctness*, and chaining operations together (e.g., multiply then decrypt) would contaminate one operation's timing with another's. This is exactly why `decrypt` is tested completely independently elsewhere in the grid.

---

## Phase 4 — What We Measure, and Why

- **Latency** — how long one operation takes, in milliseconds. Matters for anything a person is waiting on (e.g., a doctor waiting on an encrypted result).
- **Energy** — joules consumed, read from the CPU's built-in RAPL power counters. Matters for battery-powered devices and data-center power/environmental cost. **This is the metric missing from every one of the thesis's six corpus papers — a genuine original contribution.** Measured once per full 105-run invocation (not per single iteration, since reading the counter itself adds overhead) — hence the `n=1_invocation_not_repeated` label on these rows.
- **Memory** — peak RAM used. Matters because it can be a hard *pass/fail* limit: if a device has less RAM than an operation needs, the operation simply cannot run, regardless of speed. Same one-per-invocation measurement caveat as energy.

**Why all three, not just one:** a library can look excellent on one axis while hiding a weakness on another (fast but power-hungry, or fast and efficient but memory-heavy). Reporting all three honestly, side by side, is also *why* the earlier idea of a single "compromise index" combining them was dropped — it would have hidden exactly the trade-offs that matter.

### Note — Chapter 3's full six-metric definition, now fully implemented

Chapter 3's own methodology defines **six** metrics in total, not three. The following three are established in the literature (HEProfiler, Pambudi 2025) and, as of this update, are **fully implemented, swept across the full grid, and aggregated** by `bench_seal.cpp`:

| Metric | Precedent | Status |
|---|---|---|
| Storage / serialized ciphertext & key size | Pambudi 2025, Takeshita 2025 | **Done** — `--operation=size` |
| Noise budget evolution (tracked numerically) | Pambudi 2025 | **Done** — `--operation=noise_trace` (BFV/BGV only) |
| CKKS error accumulation | Takeshita 2025 | **Done** — `--operation=ckks_error` (CKKS only) |
| Bootstrapping latency | Takeshita 2025 | N/A for SEAL — not implemented by the library |

Storage is a lightweight, deterministic pass (no repetitions needed). Noise budget and CKKS error required a *chained* measurement (encrypt → check → op → check...), architecturally different from the isolated-operation design used for Standard/Constrained/Edge-Batch — a second experiment layered on top of the existing one, not a replacement or a redo. Real findings (e.g. the N=2048/cat1 zero-noise-budget-from-the-start result, cross-validated independently by the CKKS error trace; the `max_abs_error` vs. `mean_abs_error` HIGH_VARIANCE split) are in `docs/phase_logs/SEAL_HARNESS_PHASE_LOG.md`, not repeated here.

---

## Phase 5 — Making the Numbers Trustworthy

**Why 100 repetitions.** No single timed run is fully trustworthy — background OS activity, cache state, and other noise cause natural run-to-run wobble. Running 100 times and looking at the pattern, not any one result, cancels out that random wobble.

**Why the first 5 are discarded ("warm-up").** The very first runs on a computer are artificially slow — caches aren't warmed up yet. This startup cost has nothing to do with the operation itself, so it's discarded; only the remaining 100 are counted.

- **Mean** — the average of the 100 measurements.
- **Standard deviation (std)** — how spread out those measurements were. Small = consistent; large = noisy.
- **95% confidence interval** — a precise statement of certainty: if the whole 100-run experiment were repeated from scratch, the true average would land in this range 95% of the time.

**The HIGH_VARIANCE flag (std > 5% of the mean).** `add` was flagged nearly every time; `keygen` almost never. This isn't a machine problem — it's that ordinary background noise is large *relative to* a fast operation like `add` (~0.01ms) and tiny *relative to* a slow one like `keygen` (tens of ms). Fast operations are inherently harder to time precisely — the flag is detecting exactly that, correctly.

---

## Phase 6 — The Three Scenarios

**Standard** — full, unrestricted machine. The baseline every other scenario is compared against.

**Resource-Constrained** — Docker simulates the exact resource ceiling of the Raspberry Pi 4 used in Rahman et al. (2024): 4 CPU cores, 4GB RAM, on the same physical machine. Analogy: testing a recipe using only 2 of 4 stove burners, on the *same* stove — real information about sensitivity to less resource, but not a test of genuinely different hardware. Result: statistically indistinguishable from Standard, because SEAL's actual footprint (~68MB) never approached the 4GB ceiling.

**Edge/Batch** — tests a *stream* of many already-packed ciphertexts processed back-to-back (not to be confused with SIMD slot-packing, which happens inside every ciphertext in every scenario already). Grounded directly in Gouert et al. 2023 (PoPETs), which distinguishes latency (one operation, one value) from throughput (values/second under batching) — a real, peer-reviewed, independently-cited paper (DOI: 10.56553/popets-2023-0075), not an invented technique. The underlying idea (SIMD/CRT-based batching) traces back over a decade further, to Smart & Vercauteren (2011).

**The warm-up-printer analogy, with numbers.** A printer needing a fixed 5-minute warm-up: print 1 page, and that page "carries" the full 5 minutes. Print 100 pages in the same warmed-up session, and the same 5 minutes divides across all 100 — about 3 seconds per page. **The printer did not get faster; the fixed cost is simply shared across more output.**

**Real result, same logic:** keygen (the one-time setup) amortized cleanly — 68.3 ms/item at batch 1 → 6.8 ms/item at batch 10 → 0.68 ms/item at batch 100. But encrypt/decrypt/add/multiply/relinearize — the recurring, per-item work — stayed flat (ratios 0.82×–1.49×, no consistent direction). This makes sense because slot-packing efficiency was already present from the very first ciphertext in Standard; there is no *second* discount hiding underneath the first one.

**A caveat, not a headline claim:** apparent per-item *energy* improvement at larger batch sizes is attributed to fixed Docker/invocation-level overhead diluting across more processed items — not a genuine drop in the FHE operation's own computational cost — consistent with the flat latency result.

**The correct practical takeaway for the final documentation:**

> The Edge/Batch results indicate that key generation cost amortizes effectively when keys are reused across many operations, but individual cryptographic operations (encryption, decryption, addition, multiplication) show no efficiency gain from being processed in groups versus individually. This confirms that FHE deployments should generate keys once and reuse them across the full operational lifetime, while operation-level throughput scales linearly with volume rather than benefiting from batched processing.

(Note: this is about key *reuse*, not about queuing or delaying individual operations — grouping the operations themselves provides no measured benefit.)

---

## Phase 7 — Connecting Back to the HEProfiler Reproduction

Early in the project, SEAL/HEAAN/HElib were run using HEProfiler's own published parameters and protocol, and the results compared against HEProfiler's already-published numbers. **This was a calibration check, not a thesis result** — like testing a new kitchen scale against an item whose weight is already printed on the package. Agreement earns the right to trust the same tools (`perf`, RAPL) on genuinely new measurements afterward.

HEProfiler's own graphs plot metrics against **multiplicative depth** (not time) — throughput, error, and ciphertext/key size, one line per library, as depth increases. The thesis's own results carry a depth column in every row, so the same style of plot is directly reproducible from the existing data — this is planned future plotting work, not a gap.

### Planned comparative graphs

1. **Metric vs. depth**, one line per operation — same style as HEProfiler's own figures.
2. **Standard vs. Constrained**, side-by-side bars — visual proof the resource cap never bound.
3. **Metric vs. security category**, fixed N — the real-numbers companion to the Phase 2 noise diagram.
4. **Metric vs. N**, fixed category — the "bigger box, slower to carry" trade-off as a curve.
5. **Edge/Batch amortization curve** — per-item keygen cost (sharply falling) alongside per-item encrypt/decrypt/add/multiply (flat), same chart — the single clearest proof of the Phase 6 finding.
6. **Latency / energy / memory side by side**, per operation — the visual argument for measuring all three.
7. **(Later) Cross-library comparison** — SEAL vs. OpenFHE vs. HElib vs. Lattigo, same operation and parameters — the eventual headline thesis figure, once more libraries are complete.

---

## Phase 8 — The Actual SEAL Results, Explained

- **144 possible configs → 112 succeeded, 24 correctly skipped, 8 genuinely failed.** The 24 skips are every depth-0 parameter set behaving exactly as Phase 2 predicts — no budget left for even one multiplication. The 8 failures (all N=2048/category 5) mark where the Phase 2 trade-off breaks down entirely: too small a box to fit both a 256-bit lock and any usable budget.
- **Cost ordering (add cheapest, multiply/relinearize most expensive)** follows directly from Phase 3's three-part-result mechanism.
- **Energy and memory rising steadily with N** is the same "bigger box, more to carry" idea from Phase 2, on a different ruler.
- **83 of 112 latency rows flagged HIGH_VARIANCE** — Phase 5's explanation exactly: fast operations are inherently harder to time precisely than slow ones; not a machine issue.
- **Standard ≈ Constrained** — Phase 6's stove analogy confirmed with real numbers: SEAL's ~68MB footprint never approached the 4GB cap.
- **Edge/Batch's two findings** — keygen amortizes linearly; recurring operations stay flat — are the printer story, now with real measured numbers behind it.

---

*End of document. Companion diagram: `noise_budget_explained.svg`. Suggested location in the project: `docs/teaching/FHE_and_SEAL_Concepts_Explained.md`.*
