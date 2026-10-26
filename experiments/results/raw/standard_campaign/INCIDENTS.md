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
