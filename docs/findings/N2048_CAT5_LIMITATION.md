# Finding: SEAL prime-search failure at N=2048, NIST category 5

## Summary
At the smallest tested ring dimension (N=2048) combined with NIST category 5
(256-bit security), SEAL's automatic prime search fails outright —
`"failed to find enough qualifying primes"` — for **every** operation
(keygen, encrypt, decrypt, add, multiply, relinearize), in **both** BFV and
CKKS. This accounts for 8 of the 144 Standard-scenario cells (4 non-depth
operations × 2 schemes). `multiply`/`relinearize` at this same (N, category)
cell are excluded separately by the depth=0 rule and are not counted among
these 8 — the two limitations are distinct and both apply here.

## Root cause
Per `experiments/config/param_grid.csv`, N=2048/category 5 uses a two-prime
chain of 14+15 bits (`logq_used = 29` bits total) to hit 256-bit security at
this ring dimension — the value mandated by HomomorphicEncryption.org's
standard security table, not a value chosen by this harness. SEAL's prime
search must find NTT-friendly primes (primes p ≡ 1 mod 2N) within each
specified bit-length, mutually distinct and distinct from any
key-switching/special prime. At N=2048, the pool of NTT-friendly primes in a
14–15 bit window is small to begin with, and shrinks further once already-
chosen chain moduli are excluded. The search space collapses to the point
where SEAL cannot assemble a valid modulus chain at this (N, security)
combination at all — not for one operation, not for one scheme, but
structurally, for the whole cell.

## Why this is a finding, not an artifact
- **Library-scheme-independent**: reproduces identically for BFV and CKKS,
  tied purely to the (N, security level) pair, not to a scheme's specific
  arithmetic.
- **Deterministic and internally driven**: the failure comes from SEAL's own
  parameter validation, not from resource limits, timeouts, Docker, or this
  harness's measurement tooling.
- **A genuine parameter-selection tension**: the abstract (N=2048, 256-bit)
  pair is "valid" per HomomorphicEncryption.org's table, but the total
  modulus budget it implies at this ring dimension (~29 bits) is too tight
  for automatic NTT-friendly-prime search to actually succeed in practice.
  Being valid on paper and being constructible in a real implementation are
  not the same thing, and this cell is where they come apart for SEAL.

None of the six corpus papers surveyed in the literature review surface this,
because none of them sweep a ring dimension as small as N=2048 at the
highest NIST security category — they either skip that corner of the grid or
don't test high-security/small-N combinations at all. That absence is itself
worth noting in Chapter 5: it suggests published comparative benchmarks may
be systematically avoiding, or simply never reaching, the region of
parameter space where this failure mode lives.

## Disposition
Resolved as **option (a)** from the original three options in
`docs/phase_logs/SEAL_HARNESS_PHASE_LOG.md`: documented as a finding, not
patched around.
- The 8 affected cells stay `MISSING` in `seal_standard.csv` — no fabricated
  numbers, no silent substitution.
- `param_grid.csv`'s N=2048/category 5 chain is left exactly as specified by
  HomomorphicEncryption.org's table, not hand-adjusted to a "friendlier"
  split — adjusting it would hide the finding rather than report it.
- Chapter 5 should state this as its own result: the smallest tested ring
  dimension (N=2048) cannot practically support NIST category V security in
  SEAL, independent of — and in addition to — the separately-documented
  depth=0 architectural limitation at the same cell.
