# Running the SEAL Experiment (Docker setup)

This is the **real thesis experiment** for SEAL (BFV, CKKS) — implements
Chapter 3's protocol exactly. It is separate from `validation/seal/`, which
was only ever a reproduction of the HEProfiler paper and contributes no
results here.

You installed SEAL inside a Docker image (`seal-env` from Phase 3), so
everything below runs *through* Docker — you never need to go looking for
SEAL on your bare machine.

## 1. One command does build + a first test run

```bash
cd experiments/seal
bash docker_build_and_run.sh
```

**What this actually does**, step by step, so it isn't a black box:
1. Opens your `seal-env` container and searches inside it for SEAL's files
   (its header, its compiled library, and two dependencies SEAL needs).
2. Prints exactly what it found — you'll see file paths scroll by.
3. Compiles `bench_seal.cpp` using those paths.
4. Runs the compiled program **once**, on one configuration (CKKS, N=8192,
   security category 1, the "multiply" operation, 20 repetitions).
5. Prints the resulting file — 25 lines, one per repetition, each with a
   timing in milliseconds.

If step 5 prints a table of numbers like `SEAL,CKKS,8192,1,multiply,5,0.53,measured`,
**that's success** — the whole pipeline works, end to end, on your machine.

If your image isn't named `seal-env`, check with `docker images` and run
instead: `IMAGE=your-image-name bash docker_build_and_run.sh`

## 2. If it stops with "STOP: could not auto-locate SEAL"

Paste the whole output back here and we'll fix the paths together — no
guessing needed, the script tells you exactly which of the 5 required files
it couldn't find.

## 3. Run the full sweep

Now that the one-off test works, the same "through Docker" approach runs
everything: 12 parameter-grid rows x 2 schemes (BFV, CKKS) x 6 operations =
144 calls (a few will print `SKIPPED` for depth==0 configs — that's correct,
not an error).

**Scenario A (standard, unconstrained):**

```bash
cd experiments/scripts
./run_standard_docker.sh
```

Each cell is wrapped in `perf stat` on your host for energy (RAPL reads the
whole physical CPU package, so it works correctly even though the actual
computation happens inside a container) and a small `/proc`-polling wrapper
*inside* the container for peak memory (no extra packages needed — the
seal-env image doesn't have GNU `time` installed, so we measure it directly
instead). This will run for a while, especially on `multiply`/`relinearize`/
`keygen` at N=16384 — let it finish rather than interrupting partway.

**Scenario B (simulated resource-constrained — Raspberry Pi 4 ceiling):**

```bash
./run_constrained_docker.sh
```

Same sweep, but each container is capped to 4 CPU cores and 4 GB RAM via
Docker's own `--cpuset-cpus`/`--memory` flags — simpler than the manual
cgroup setup from the original plan, since Docker already manages this for
us. No `sudo` needed beyond whatever your normal `docker run` already
requires.

## 4. Aggregate

```bash
python3 aggregate.py --scenario=standard
python3 aggregate.py --scenario=constrained
```

Produces `results/final/seal_standard.csv` and `seal_constrained.csv` — the
only files Chapter 5 should read from. Watch for `HIGH_VARIANCE` flags in
the terminal output; a few is normal, many means something else was busy on
your machine during the run.

## Output schema reference (for later, once the full sweep runs)

```
library,scheme,N,category,scenario,operation,metric,mean,std,ci_low,ci_high,flag
```

`metric` is one of: `latency_ms`, `energy_pkg_j_per_op`, `peak_memory_mb`.
No compromise index column — confirmed removed from this pipeline.
