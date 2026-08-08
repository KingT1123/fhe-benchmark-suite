# Does Our Methodology Align With the Field? A Paper-by-Paper Answer

This document exists to answer one question directly: **is what we built in
Chapter 3 actually grounded in how this field does research, or did we
invent our own approach?** The honest answer, backed by what's actually in
each of your six papers: grounded, deliberately, in specific citable places
— and extended past all six of them in a few specific, defensible ways.

---

## 1. What each paper actually did (the raw facts)

| Paper | Libraries | Schemes | Hardware | Statistical protocol | What it does NOT do |
|---|---|---|---|---|---|
| **SoK 2023** (Gouert et al.) | SEAL, OpenFHE, HElib, Lattigo, TFHE | BFV, BGV, CKKS, TFHE | Not the focus — methodology paper | Fixed/identical parameters forced across all libraries ("T2" standardized approach) | Energy, NIST-style mapping, IoT, composite index |
| **IoT 2024** (Rahman et al.) | OpenFHE, SEAL, Lattigo (HElib excluded — unstable on ARM at the time) | BFV, BGV, CKKS | Raspberry Pi 4, ARM Cortex-A72, 4GB RAM | Not clearly specified in the paper | Energy, NIST mapping, composite index, HElib |
| **Cross-platform 2025** (Faneela et al.) | SEAL, OpenFHE only | BGV, CKKS only | Laptop, Intel i7-8550U, 16GB RAM | Not clearly specified | Energy, NIST mapping, HElib, Lattigo, IoT hardware |
| **ACM 2025** (Pambudi et al.) | All 4: SEAL, HElib, OpenFHE, Lattigo | All 3: BFV, BGV, CKKS | **Not documented in the paper at all** | Not clearly specified | Energy, NIST mapping, composite index, bootstrapping, reproducible hardware description |
| **HEProfiler 2025** (Takeshita et al.) | PALISADE (~OpenFHE), SEAL, HElib, HEAAN (Lattigo deliberately excluded, citing cross-language fairness) | CKKS only | Intel Xeon Gold 6226, 192GB RAM, RTX6000 GPU (HEAAN only), Linux/Singularity | **50 iterations, average latency + error reported** — no stated warm-up discard, no confidence interval | Energy, NIST mapping, composite index, BFV/BGV, Lattigo |
| **SecITC 2018** (Aguilar Melchor et al.) | HElib, SEAL v2.1/2.3, FV-NFLlib | BGV, BFV/FV only (CKKS didn't exist yet) | Single core, Xeon E5-2695 v3 | Ran until cost exceeded 12 hours; no repetition/CI protocol stated | Everything modern — this paper is cited for historical framing only |

**The one-sentence version:** every single paper in your corpus measures
timing (and sometimes memory), on one platform, with informal or unstated
statistical treatment, and none of them measure energy, map to security
categories, or propose a way to combine multiple metrics into one score.

---

## 2. Your Chapter 3, mapped to exactly what it's grounded in

This isn't a vague "inspired by the literature" — every methodological
choice in your Chapter 3 has a specific citation attached to it, and now
that the SEAL harness is real and running, you can see those choices
actually implemented:

| Your choice | Grounded in | What it actually says |
|---|---|---|
| `perf stat` + RAPL for latency AND energy together | Khan et al. 2018 ("RAPL in Action") | One instrument avoids timing mismatches from stitching two separate tools together |
| Package + core energy primary, DRAM energy secondary | Desrochers, Paradis & Weaver 2016 | DRAM-domain RAPL accuracy is less firmly established than package/core |
| `/usr/bin/time -v` + `getrusage()` for memory | Pambudi 2025, Faneela 2025 | Same tool class these two papers already used |
| Serialized byte length for ciphertext/key sizes | Takeshita et al. 2025 (HEProfiler) | Same measurement method as the most technically deep paper in your corpus |
| Standard (unconstrained) scenario | Pambudi 2025, Takeshita 2025 | Mirrors their platform assumptions directly |
| Resource-constrained scenario (4 cores/4GB, simulated) | Rahman et al. 2024 | Explicitly reproduces *their* Pi 4 ceiling — with the honest, stated caveat that architecture (ARM vs x86-64) isn't reproduced, which matches Rahman et al.'s own observation that ARM/x86-64 results aren't directly comparable |
| Edge/batch throughput scenario | Gouert et al. 2023 (SoK) | Directly uses their latency-vs-throughput distinction as the scenario's rationale |
| Linux (Ubuntu 24.04) as the OS | Faneela et al. 2025 | Their own finding: Linux consistently outperforms Windows for FHE, so Linux is the reproducible choice |
| $N \in \{2048, 4096, 8192, 16384\}$, security-tiered chains | Homomorphic Encryption Standard (Albrecht et al. 2021), refined by Bossuat et al. 2024 | **Not** a literal NIST document — NIST has no dedicated FHE standard. Your own Chapter 3 text is already careful to say "NIST-*style*" categories, borrowing the tiered I/III/V naming convention while the actual security bound comes from the HE Standard consortium. Worth keeping that phrasing precise if anyone on your committee asks "is this actually NIST." |
| Warm-up discard (5 runs) + mean/std/**95% CI** + 5%-variance flagging | Weiser et al. 2018 ("Benchmarking Crimes") | **Not from any of your six FHE papers** — this comes from the general software-benchmarking-hygiene literature. See §3, this is your one genuine methodological *upgrade* over the field, not just a scope extension. |

---

## 3. Where you don't just extend the field — you correct a real gap in it

This is worth stating plainly because it's easy to undersell: **not one of
your six papers reports a confidence interval or explicitly discards
warm-up runs.** HEProfiler — the most rigorous paper in your corpus —
reports "50 iterations, average latency," full stop. No mention of
discarding early runs, no variance reported, no way for a reader to know if
that average is trustworthy or noisy.

Your protocol (100 reps, discard first 5, report mean/std/95% CI, flag
anything with >5% relative variance) is stricter than every paper in your
own literature review. This is exactly the kind of thing that turned out to
matter in practice: the `check_variance.py` breakdown we ran on your real
SEAL data (add/encrypt/decrypt showing 95-100% flagged, keygen showing 0%)
is a diagnostic none of these six papers could have produced — they don't
capture the variance in the first place. That's not a small thing to be
able to say in a methodology chapter.

---

## 4. Two places where you *deliberately diverge* from a paper's approach — worth stating outright, not hiding

**4a. Parameter selection strategy: fixed vs. per-library.** SoK (2023)
forces identical parameters across every library, arguing this is the only
fair comparison. HEProfiler (2025) explicitly disagrees, letting each
library use its own automatic parameter selection, arguing that's what real
users actually experience. **Your thesis follows SoK's fixed-parameter
approach** (the same $N$/category grid applied identically across SEAL,
OpenFHE, HElib, Lattigo). That's a defensible, deliberate choice — but it
means you're implicitly taking a side in a real methodological disagreement
between two papers in your own corpus. Worth one sentence in Chapter 3
acknowledging this explicitly (something like: *"This thesis follows the
fixed-parameter convention of Gouert et al. (2023) rather than the
per-library auto-selection approach of Takeshita et al. (2025), prioritizing
direct cross-library comparability over each library's idiomatic usage
pattern"*) — it shows the committee you know the tension exists rather than
having picked a side by accident.

**4b. Including Lattigo despite HEProfiler's stated objection.** Takeshita
et al. explicitly excluded Lattigo from HEProfiler, citing cross-language
(Go vs C++) fairness concerns. Your thesis includes it anyway — which is
fine, and arguably strengthens your thesis (Pambudi 2025 and Rahman 2024
both include Lattigo without issue, and Rahman's finding that Lattigo is
"surprisingly competitive" is itself a finding worth having in your own
dataset). But it's a place where you're siding with three papers over one,
not blindly following everyone. Same advice: one sentence acknowledging the
disagreement makes your methodology chapter read as informed rather than
as having missed it.

---

## 5. The compromise index — reconciling what the literature notes say vs. what you decided

Your literature-review notes (written earlier in this project) frame the
compromise index $C = \frac{\text{Security}}{\text{Time} \times \text{Energy}}$
as your headline original contribution — and confirm it appears in **none**
of the six papers, so it genuinely would have been novel. Since then, in
this conversation, **you made the call to drop it**, because you couldn't
establish it as a provably pertinent measure — and that decision has already
propagated through the actual pipeline (no compromise-index column
anywhere in `seal_standard.csv`, no compromise-index code in `aggregate.py`).

This isn't a contradiction to resolve — it's just two different moments in
the project that need to agree in your write-up. The literature notes were
right that no paper does this; you were separately right that "no one else
does it" isn't the same as "it's a valid metric." **What replaces it as your
original contribution** is now: energy measurement itself (which, per the
table in §1, is absent from every single paper in your corpus), the security
mapping, and the fact that you test all four libraries × all three schemes
× three security tiers together, which no single existing paper does.

---

## 6. Bottom line

Your methodology isn't "aligned with the field" in a vague sense — it's
assembled, citation by citation, from the specific methodological choices of
these six papers, filling the one gap every single one of them shares
(energy), and going stricter than all of them on statistical rigor. The two
places you diverge from a specific paper's choice (fixed parameters over
per-library selection; including Lattigo) are defensible and already
consistent with the majority of your own corpus — they just deserve one
explicit sentence each in Chapter 3 so they read as informed decisions
rather than oversights.
