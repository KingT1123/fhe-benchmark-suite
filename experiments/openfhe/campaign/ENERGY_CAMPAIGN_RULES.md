# Energy/memory campaign, SEAL and OpenFHE: rules fixed before the campaign

Written before any stage-1 check or campaign session is run (review of
`energy-validation-v1`). The thresholds below come from the two validation
sessions e1 and e2 (`results/raw/energy_validation/`); they are not adjusted
after seeing campaign data.

## 1. Measurements

- Runner: `openfhe/run_energy_campaign.sh <session> <plan>`; protocol of the
  validation, unchanged: boost disabled for the whole session, governor
  performance, one pinned core, mains power only, randomized order (seed
  recorded), power state every second, two session idle windows.
- Matrix: `campaign/energy_plan_campaign.csv` (206 cells): every valid cell of
  the Standard latency campaign except rotation. Per cell and session:
  2 energy invocations, 3 memory invocations.
- **Rotation: energy and peak RSS are not available.** One rotation per
  repetition lasts a few milliseconds and SEAL's rotation branch does not read
  the energy counter. The runner refuses a plan that contains rotation, and
  `validate_cell.py` rejects an energy reading of zero.
- Reported values: gross package energy per operation (primary);
  idle-corrected energy (secondary) with the session baseline = median of the
  session's own idle readings, and its sensitivity (lowest and highest
  reading, the two session idle windows); observed peak process RSS.
- Two sessions on two different days (`day1`, `day2`; see section 5). Results are reported by
  session. A ratio between the libraries is formed only for matched-profile
  cells with equivalent boundaries, within one session.

## 2. Runs that are repeated

Only two events cause a run to be measured again; both are decided by the
runner, never by looking at the values:

1. **Loss of mains power** during an invocation or an idle window, even for
   one second: the invocation is set aside (files kept in
   `<session>/invalid/<timestamp>/`, listed in `set_aside.csv`) and measured
   again once mains has been back for 2 minutes.
2. **Invalid cell** (incomplete output, failed correctness check): moved to
   `invalid/`, the session stops, and the cell is measured again on resume.

No run is repeated because its value looks unusual.

## 3. Disturbed runs: flags

A flag marks a run; it never removes it. Flags are computed by `aggregate.py`
from the recorded data only.

| Flag | Level | Condition |
|---|---|---|
| `high_idle` | invocation | its own idle reading > 1.15 x the session median of idle readings |
| `pair_disagreement` | cell, session | gross energy of the two invocations differs by more than 10% (ratio outside 0.90-1.10) |
| `frequency` | invocation | a sample of the pinned core above 3300 MHz during the invocation, or boost recorded on |
| `idle_window` | session | the start or the end idle window > 1.15 x the session median of idle readings |
| `operator` | session | any use of the laptop during the session, recorded in the incident log |

Calibration of the 1.15 factor: in the undisturbed session e2 the highest idle
reading was 1.09 x the median; in e1, the readings taken while the laptop was
in use were 1.16 x the median or more.

Treatment:

- every valid run is kept in the raw data and appears in the per-session
  tables, with its flags;
- each summary is given twice: with all valid runs, and without the flagged
  invocations, so that the effect of the flags is visible;
- the laptop is not used during a session (no terminal, no monitoring
  command); progress is read after the session ends.

## 4. Stage-1 checks (before the campaign)

1. **Mains guard** (`energy_plan_guard.csv`, session g1, `GUARD_TEST=1`): the
   charger is unplugged during an energy invocation. Expected: the invocation
   is listed in `set_aside.csv`, its files are kept in `invalid/`, it is
   measured again and valid.
2. **Window test** (`energy_plan_window.csv`, session w1): encryption and
   multiplication at CKKS 8192/1 in both libraries with blocks of about 5,
   10, 20, 50 and 100 ms, and key generation (CKKS and BFV 8192/1, both
   libraries) with 100 repetitions. Analysis, fixed here:
   - for each library and operation, gross energy per operation at each block
     length relative to the 50 ms block;
   - least-squares line E_block = c + e x n over all measured blocks (n =
     operations in the block): c estimates the energy attributed to a block
     independently of its content (counter-read overhead and edge effects),
     reported with its 95% confidence interval.
   Decision rule for the short key-generation blocks of OpenFHE (about 18 ms,
   one key generation per block):
   - if the energy per operation of the 20 ms blocks is within 5% of the 50 ms
     blocks, and |c| is below 5% of the energy of one OpenFHE key-generation
     block, the single-operation block is accepted as it is, and the number of
     repetitions is the smallest multiple of 10, at least 30, for which the
     95% confidence half-width of the mean is at most 5%, computed from the
     largest relative standard deviation of the OpenFHE key-generation runs of
     this test;
   - otherwise the result is reported before any campaign session is run.
3. **Short check** (`energy_plan_check.csv`, session c1): 36 cells, including
   two configurations outside the validation (CKKS 16384/1, BFV 4096/3), the
   key-switching cells of BGV 8192/3, and the OpenFHE-only operations.
   Expected: `session_check.txt` reports every energy and peak-RSS file
   present and valid (`scripts/verify_energy_session.py`).

All data of the stage-1 sessions are kept under
`results/raw/energy_campaign/`.

## 5. Change after session d1 (16 November 2026)

Session d1 (started 15 November) stopped at invocation 484 of 1030, as the
validator requires: an OpenFHE key generation at CKKS N=2048 lasts about
0.8 ms, and the energy counter (updated about once per millisecond) read 0
for one repetition. The window test had covered key generations of about
18 ms only; eleven OpenFHE key-generation cells of the matrix last 0.6-7.4 ms
(boost on), and the valid d1 readings of the shortest ones varied by up to
40% (relative standard deviation), mostly from the counter's resolution.

Change, made before any campaign result was analysed:

- a key generation shorter than 10 ms at fixed frequency (OpenFHE only;
  every SEAL key generation lasts at least 11 ms) is timed as K complete key
  generations in one window of about 50 ms, like every other operation
  (`bench_openfhe --keygen-per-window=K`, K in the plan's inner_loop column);
  latency and energy are divided by K. Each key generation still starts from
  an empty context cache. Other key generations are unchanged (K = 1);
- effect on latency, measured before the campaign (BFV N=4096 cat 3, 30
  repetitions, twice): 1.72 ms per key generation with K = 26 against
  1.89 ms with K = 1 (-9%), the warm-up effect already present in every
  block of the other operations. This is stated with the results;
- d1 is kept as it is (`results/raw/energy_campaign/d1/`, with its console
  log) and is not used for results. The campaign is run as two new sessions,
  `day1` and `day2`, with the new plan; a session may be stopped (Ctrl+C) and
  resumed with the same command: valid invocations are kept and skipped.
