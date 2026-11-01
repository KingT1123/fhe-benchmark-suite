# OpenFHE Standard campaign — incident log

Every interruption, anomaly or tooling problem met during the campaign is
recorded here, with its effect on the data and what was done. No measurement
was discarded without an entry in this file.

## 1. Session s1 relaunched by mistake (2026-10-25, ~23:52)

* What: after s1 had completed (94/94 valid), the s1 command was launched
  again instead of s2.
* Effect: none. The runner compared the session manifest, found a different
  recorded code commit (the repository HEAD had moved because the s1 results
  had been committed) and stopped before measuring anything (exit 4). No file
  of s1 was changed.
* Tooling problem revealed: recording the repository HEAD would also have
  blocked legitimate resumes after results were committed. Fixed in 9b86511:
  the manifest records the last commit that changed the code
  (experiments/{openfhe,seal/src,scripts,config}). Tested (resume accepted
  after a results-only commit).

## 2. Session s2 stopped by the operator and resumed (2026-10-26)

* What: s2 was stopped at 07:0x (operator had to leave), during cell 47/48,
  with `pkill -f run_standard_campaign.sh; docker ps -q | xargs -r docker stop`.
* Effect on measurements: the interrupted cell had written no output file
  (the harnesses write only complete, fully checked cells); the 46 completed
  cells were valid. Resumed at 08:24 with an identical manifest: 46 cells
  reused, the 2 remaining measured. 48/48 valid.

## 3. Session s3 interrupted by a power failure and resumed (2026-10-26)

* What: the laptop switched off at about 13:53 during cell 37/42
  (openfhe_ckks_N8192_cat3_multiply). After restart the battery was at 3 %:
  the machine ran on battery (charger disconnected or mains failure) until it
  was empty. The thermal log of that run showed the effective core frequency
  falling (1.6–2.4 GHz) only in its last seconds, 13:53.
* Effect on measurements: the interrupted cell had no output file and was
  measured again on resume (15:12, identical manifest; 36 cells reused, 6
  measured). 42/42 valid. The cells completed before the failure show no sign
  of a slowdown: temperatures at their start 91–92 °C (normal full load),
  coefficients of variation 0.3–3.0 %, and SEAL's latencies in s3 relative
  to the archived SEAL campaign 0.855–0.997 (median 0.925), the same band as
  s1 (0.80–1.01, median 0.917) and s2 (0.84–1.00, median 0.914). No cell
  is excluded.

## 4. Thermal/frequency log overwritten on resume (tooling bug, s2 and s3)

* What: session_lib.sh re-created thermal_log.csv (header written with `>`)
  at every (re)start, so the resumes of s2 and s3 erased the per-second
  frequency/temperature records of their earlier parts:
  - s2: record kept only from the resume (08:24, cells 47–48); the record of
    cells 1–46 (2026-10-25 23:55 → 2026-10-26 07:0x) is lost;
  - s3: record kept only from the resume (15:12, cells 37–42); the record of
    cells 1–36 (08:55 → 13:53) is lost.
* What remains for those parts: the CPU temperature at the start of every
  cell (console logs, console.log / console_resume.log), the start/end time
  of every cell (cell_times.csv), the CPU state at each (re)start
  (cpu_state_<timestamp>.txt), and the measurements themselves.
* Effect on measurements: none (the measurements and their checks are
  complete); the environmental record of those parts is incomplete, which is
  stated wherever per-session conditions are reported. Indirect evidence of
  stable conditions: SEAL-vs-archive ratios per cell (item 3).
* Fixed in 70dc8f0 (the log is appended across restarts; tested: a resumed
  dry session keeps its earlier records). Sessions s4 and s5 are unaffected.

## 5. Cells of s4 measured on battery power, set aside and measured again (2026-10-26 → 28)

* What: on this laptop, running on battery makes the firmware lower the
  CPU's power limit, so the core frequency drops (to about 4.23–4.32 GHz
  against 4.40–4.46 GHz on mains, with the fans slowing from about 5500 to
  3900 rpm). Two parts of s4 ran partly or wholly on battery:
  - 2026-10-26, 18:34–19:37: cell openfhe_bfv_N16384_cat1_add (the run was
    then ended by the closing of its terminal, `bash terminated by signal
    HUP`, during cell 2; resumed at 21:54, identical manifest);
  - 2026-10-27, from about 04:00 to the end of the session at 11:05: 8 cells
    (seal relinearize, decrypt, encrypt; openfhe multiply, encrypt,
    decrypt, decrypt_full, keygen).
  Detected from the per-second frequency/fan record (thermal_log.csv), the
  system journal (AC-power conditions) and the latency series.
* What was done: these 9 cells passed every validity check (they are
  correct computations), but their timings were taken in a different power
  state, so they were set aside, not deleted:
  `s4/set_aside_battery_20261026/` (1 cell) and
  `s4/set_aside_battery_20261027/` (8 cells), with their checks, memory
  logs and configuration cards. They are not read by aggregate.py. They
  were measured again with an identical manifest, on mains:
  the 8 on 2026-10-27 16:16–23:06 (4.36–4.44 GHz), the add on
  2026-10-28 01:04–02:08 (4.27 GHz).
* Remaining effect: the re-measured add ran at a lower frequency than the
  rest of s4 (4.27 against 4.36–4.46 GHz), on mains, in the same power
  profile (see item 8). It is kept: s4 is a separate-analysis configuration
  (no OpenFHE/SEAL ratio is reported for it) and add is reported as an
  end-to-end API cost. Its effective frequency is reported with it.

## 6. Power guard introduced (tooling, from s4 attempt of 2026-10-27 16:16)

* What: to stop any further measurement on battery, the remaining runs were
  launched through `experiments/tools/power_guard.sh` (outside the
  manifest's code-commit directories; it changes nothing in how a cell is
  measured). It records the mains state and battery level every 5 s
  (`<session>/power_log.csv`), stops the session if mains power is lost for
  10 s, sets aside any cell stopped between its output and its
  configuration card, and resumes the same command once mains has been
  back for 2 minutes. Tested beforehand on dry sessions with a simulated
  power loss (two defects found and fixed during those tests: the stop did
  not reach the running container; a cell stopped between output and card
  blocked the resume).
* Effect: from 2026-10-27 16:16 on, no cell of s4 or s5 was measured on
  battery (power_log.csv: every `running` record has mains online).

## 7. Interruptions of s5 (2026-10-28 → 2026-11-01)

The s5 session ran in five attempts (power_log.csv; console_guard1–5.log).
Every resume had an identical manifest; completed cells were reused, the
interrupted cell had no output file and was measured again from the start.
* 2026-10-28 06:25: stopped by the operator (had to leave) during cell 7
  (add_inplace); 6 cells complete.
* 2026-10-29 00:46 resume; at about 04:59, during cell 14
  (openfhe relinearize, started 04:58), the machine stopped while on mains
  power: the logs end abruptly with no battery record (sudden power-off;
  cause not recorded). 13 cells complete.
* 2026-10-29 13:35 resume; 14:46 mains power lost: the guard stopped the
  measurement after 10 s (cell 14, no output); mains back 14:51, automatic
  resume 14:53.
* 2026-10-29 16:54: stopped by the operator (had to leave) during cell 14.
* 2026-11-01 09:21 resume; cell 14 measured 09:21–11:30, on mains for its
  whole duration; session complete, 14/14 valid.

## 8. Changes of machine state between parts of s4/s5 (frequency, profile, kernel)

* Frequency: with the same governor (performance) and power profile
  (balanced), the sustained core frequency differed between days, from
  about 4.25–4.35 GHz (fans about 2400–3300 rpm) to 4.40–4.46 GHz (fans
  4200–5600 rpm). The cause is not identified (a restart does not restore
  the higher level: checked 2026-10-29). Per-cell mean effective frequency
  (from thermal_log.csv) is therefore reported with the results. In s5,
  every OpenFHE/SEAL pair used for a ratio ran between 4.25 and 4.35 GHz,
  except keygen (short cells, 4.29 OpenFHE vs 4.60 SEAL); the final
  relinearize ran at 4.27 GHz against 4.31 GHz for its SEAL partner.
* Power profile: before the final s5 resume the operator had set the
  firmware profile to "performance"; it was put back to "balanced" before
  the resume (power_log.csv records `start_attempt_5_profile_balanced`).
  Every guarded attempt of s4 and s5 started in "balanced".
* Kernel: an operating-system update between 2026-10-29 and 2026-11-01
  moved the kernel from 7.0.0-38 to 7.0.0-42 (cpu_state_<timestamp>.txt).
  Only the last cell of s5 (openfhe_ckks_N16384_cat1_relinearize) ran on
  7.0.0-42; its SEAL partner ran on 7.0.0-38. The harness binaries, Docker
  images and configuration were unchanged (identical manifest). The kernel
  is not part of the manifest; this is recorded here.

## 9. Unaffected but noted

* s4 openfhe_bfv_N16384_cat1_keygen: HIGH_VARIANCE flag (relative std
  5.3 %) caused by 3 isolated slow repetitions out of 100; the median
  (85.93 ms) and interquartile range (85.53–86.56 ms) are unaffected.
* s4 openfhe_bfv_N16384_cat1_relinearize: its first 7 measured repetitions
  are slower than the rest (warm-up effect lasting beyond the 5 discarded
  repetitions); coefficient of variation 4.6 %, below the 5 % flag; the
  median is unaffected. Kept as measured.
* The console log of the first s4 run shows `nohup: ignoring input`
  and ends with `bash terminated by signal HUP`: launching with nohup did
  not protect the run from its terminal being closed. Later runs were
  launched through power_guard.sh (setsid).
