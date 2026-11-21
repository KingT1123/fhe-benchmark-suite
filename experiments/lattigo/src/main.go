// bench_lattigo -- latency harness for Lattigo v5.0.7 (latency pilot), written
// to reproduce the SEAL measurement protocol of experiments/seal/src/
// bench_seal.cpp, as bench_openfhe and bench_helib do. BFV, BGV and CKKS.
//
// Same conventions as bench_seal / bench_openfhe / bench_helib:
//   - one CLI invocation = one (scheme, N, category, operation) cell;
//   - ONE ROW PER ITERATION, no statistics here (aggregate.py only);
//   - same CSV columns (library = "Lattigo"), same --reps/--warmup/
//     --inner-loop semantics, the first --warmup rows marked "warmup";
//   - fresh inputs: everything an operation consumes is built BEFORE t0, a
//     different ciphertext for every call (inner_loop of them per rep), with
//     the same input values as bench_seal: encrypt encodes a constant
//     plaintext (CKKS every slot 0.5, BFV/BGV every slot 1); the other
//     operations use fresh ciphertexts whose slots are uniform in [-1, 1]
//     (CKKS) or in {0, 1} (BFV/BGV), from a generator seeded 12345;
//   - the timed region contains only the operation itself.
//
// Go runtime: one OS thread for Go code (GOMAXPROCS=1, set here) on the core
// the process is pinned to; a garbage collection is forced before every timed
// region (untimed), so that a collection triggered by the setup does not fall
// inside the timing; collections caused by the operation itself remain part
// of its cost, as allocations are in the C++ harnesses.
//
// FAIL-CLOSED: every repetition's result is decrypted and checked after the
// timer stops (CKKS: error normalized by max(1,|expected|) below 1e-2, SEAL's
// threshold; BFV/BGV: every slot exact mod t). Output files are written only
// when every repetition ran and passed, through a temporary file renamed into
// place; a failed check keeps the rows as <out>.invalid, exit 3; any other
// error exit 1, no output. --inject-mismatch-at=K (tests only) falsifies the
// expected value of repetition K.
//
// Configuration: lattigo/probe/lattigo_params.csv (make_params.py): SEAL's
// EXACT primes for the cell, given to Lattigo explicitly (ParametersLiteral
// Q, P); the parameters Lattigo builds are checked to hold exactly these
// primes, plaintext modulus and scale, else the run stops. Error: Lattigo's
// default discrete Gaussian, sigma 3.2 (SEAL: centered binomial, sigma about
// 3.24); secret: uniform ternary (as SEAL).
//
// Operation boundaries (Lattigo's own API):
//   keygen       parameters from the literal (ring and NTT tables for the
//                given primes: no prime generation, which SEAL's key
//                generation includes) + secret and public key + the
//                relinearization key.
//   encrypt      public-key encryption of a plaintext encoded before t0
//                (Lattigo encrypts modulo QP and divides by P, as SEAL).
//   decrypt      rlwe Decryptor.Decrypt: c0 + c1*s, result left in NTT form.
//                CKKS: SEAL's boundary. BFV/BGV: SEAL's decrypt also returns
//                to coefficient form and reduces/scales to mod t; Lattigo does
//                that in decoding.
//   decrypt_full Decrypt + Decode: end-to-end API cost.
//   add          Evaluator.Add into a pre-allocated output ciphertext.
//   multiply     Evaluator.Mul (degree-2 result, no relinearization, no
//                rescaling). BFV: Lattigo's scale-invariant tensoring
//                (MulScaleInvariant); SEAL uses BEHZ.
//   relinearize  Evaluator.Relinearize on a pre-computed product.
//   rotate       CKKS Rotate by 1 / BFV, BGV RotateColumns by 1, with ONE
//                Galois key (for that rotation only, as SEAL's step-1 key),
//                one call per repetition. BFV/BGV: each row of N/2 slots.
//   probe        (not a cell) prints what Lattigo builds and a depth test.
//
// Usage:
//   bench_lattigo --scheme=CKKS --N=8192 --category=1 --operation=multiply \
//     --reps=100 --warmup=5 --inner-loop=10 \
//     --params=probe/lattigo_params.csv --out=X.csv --check-out=X_check.csv
package main

import (
	"encoding/csv"
	"fmt"
	"math"
	"math/rand"
	"os"
	"runtime"
	"strconv"
	"strings"
	"time"

	"github.com/tuneinsight/lattigo/v5/core/rlwe"
	"github.com/tuneinsight/lattigo/v5/schemes/bfv"
	"github.com/tuneinsight/lattigo/v5/schemes/bgv"
	"github.com/tuneinsight/lattigo/v5/schemes/ckks"
)

const ckksThreshold = 1e-2 // = bench_seal.cpp CKKS_CORRECTNESS_THRESHOLD

type args struct {
	scheme, op, params, out, check  string
	n, cat, reps, warmup, inner, inj int
}

func parseArgs() args {
	a := args{reps: 100, warmup: 5, inner: 1, inj: -1}
	for _, s := range os.Args[1:] {
		kv := strings.SplitN(s, "=", 2)
		if len(kv) != 2 {
			fail(1, "bad argument "+s)
		}
		v := kv[1]
		atoi := func() int { x, err := strconv.Atoi(v); must(err); return x }
		switch kv[0] {
		case "--scheme":
			a.scheme = v
		case "--N":
			a.n = atoi()
		case "--category":
			a.cat = atoi()
		case "--operation":
			a.op = v
		case "--reps":
			a.reps = atoi()
		case "--warmup":
			a.warmup = atoi()
		case "--inner-loop":
			a.inner = atoi()
		case "--params":
			a.params = v
		case "--out":
			a.out = v
		case "--check-out":
			a.check = v
		case "--inject-mismatch-at":
			a.inj = atoi()
		default:
			fail(1, "unknown argument "+kv[0])
		}
	}
	if a.scheme == "" || a.n == 0 || a.cat == 0 || a.op == "" || a.params == "" ||
		(a.op != "probe" && (a.out == "" || a.check == "")) {
		fail(1, "required: --scheme= --N= --category= --operation= --params= --out= --check-out=")
	}
	if !strings.Contains(" BFV BGV CKKS ", " "+a.scheme+" ") {
		fail(1, "scheme must be BFV, BGV or CKKS")
	}
	if !strings.Contains(" keygen encrypt decrypt decrypt_full add multiply relinearize rotate probe ", " "+a.op+" ") {
		fail(1, "unknown --operation")
	}
	if a.inner < 1 || a.reps < 1 || a.warmup < 0 {
		fail(1, "bad --reps/--warmup/--inner-loop")
	}
	return a
}

func fail(code int, msg string) {
	fmt.Fprintln(os.Stderr, "ERROR: "+msg)
	os.Exit(code)
}
func must(err error) {
	if err != nil {
		fail(1, err.Error())
	}
}

// ---------- configuration ----------
type config struct {
	logN     int
	q, p     []uint64
	t        uint64
	logScale int
}

func parseU64s(s string) []uint64 {
	var v []uint64
	for _, f := range strings.Fields(s) {
		x, err := strconv.ParseUint(f, 10, 64)
		must(err)
		v = append(v, x)
	}
	return v
}

func loadConfig(a args) config {
	f, err := os.Open(a.params)
	must(err)
	defer f.Close()
	rows, err := csv.NewReader(f).ReadAll()
	must(err)
	h := map[string]int{}
	for i, c := range rows[0] {
		h[c] = i
	}
	for _, r := range rows[1:] {
		if r[h["scheme"]] == a.scheme && r[h["N"]] == strconv.Itoa(a.n) && r[h["category"]] == strconv.Itoa(a.cat) {
			c := config{q: parseU64s(r[h["q_primes"]]), p: parseU64s(r[h["p_primes"]])}
			c.logN, _ = strconv.Atoi(r[h["log_n"]])
			if 1<<c.logN != a.n {
				fail(1, "log_n does not match N")
			}
			if a.scheme == "CKKS" {
				c.logScale, _ = strconv.Atoi(r[h["ckks_log2_scale"]])
			} else {
				c.t, _ = strconv.ParseUint(r[h["plaintext_modulus"]], 10, 64)
			}
			return c
		}
	}
	fail(1, "configuration absent from "+a.params)
	return config{}
}

// ---------- context ----------
type ctx struct {
	scheme string
	ckks   bool
	slots  int
	t      uint64
	params rlwe.ParameterProvider
	rp     rlwe.Parameters
	sk     *rlwe.SecretKey
	pk     *rlwe.PublicKey
	rlk    *rlwe.RelinearizationKey
	encr   *rlwe.Encryptor
	decr   *rlwe.Decryptor
	// scheme-specific
	pC   ckks.Parameters
	pB   bgv.Parameters
	pF   bfv.Parameters
	encC *ckks.Encoder
	encB *bgv.Encoder
	encF *bfv.Encoder
	evC  *ckks.Evaluator
	evB  *bgv.Evaluator
	evF  *bfv.Evaluator
}

// makeParams + keys: the timed part of keygen.
func makeKeys(a args, c config) *ctx {
	x := &ctx{scheme: a.scheme, ckks: a.scheme == "CKKS"}
	var err error
	switch a.scheme {
	case "CKKS":
		x.pC, err = ckks.NewParametersFromLiteral(ckks.ParametersLiteral{LogN: c.logN, Q: c.q, P: c.p, LogDefaultScale: c.logScale})
		must(err)
		x.params, x.rp = x.pC, x.pC.Parameters
	case "BGV":
		x.pB, err = bgv.NewParametersFromLiteral(bgv.ParametersLiteral{LogN: c.logN, Q: c.q, P: c.p, PlaintextModulus: c.t})
		must(err)
		x.params, x.rp = x.pB, x.pB.Parameters
	default:
		x.pF, err = bfv.NewParametersFromLiteral(bfv.ParametersLiteral{LogN: c.logN, Q: c.q, P: c.p, PlaintextModulus: c.t})
		must(err)
		x.params, x.rp = x.pF, x.pF.Parameters.Parameters
	}
	kg := rlwe.NewKeyGenerator(x.params)
	x.sk, x.pk = kg.GenKeyPairNew()
	x.rlk = kg.GenRelinearizationKeyNew(x.sk)
	return x
}

// untimed: check the parameters, build encoder/encryptor/decryptor/evaluator.
func finish(x *ctx, c config) {
	eq := func(a, b []uint64) bool {
		if len(a) != len(b) {
			return false
		}
		for i := range a {
			if a[i] != b[i] {
				return false
			}
		}
		return true
	}
	if !eq(x.rp.Q(), c.q) || !eq(x.rp.P(), c.p) {
		fail(1, "Lattigo built other primes than lattigo_params.csv records -- stopping")
	}
	evk := rlwe.NewMemEvaluationKeySet(x.rlk)
	switch x.scheme {
	case "CKKS":
		if x.pC.LogDefaultScale() != c.logScale {
			fail(1, "Lattigo CKKS scale differs from the recorded one")
		}
		x.slots = x.pC.MaxSlots()
		x.encC = ckks.NewEncoder(x.pC)
		x.evC = ckks.NewEvaluator(x.pC, evk)
	case "BGV":
		if x.pB.PlaintextModulus() != c.t {
			fail(1, "Lattigo plaintext modulus differs from the recorded one")
		}
		x.slots, x.t = x.pB.MaxSlots(), c.t
		x.encB = bgv.NewEncoder(x.pB)
		x.evB = bgv.NewEvaluator(x.pB, evk)
	default:
		if x.pF.PlaintextModulus() != c.t {
			fail(1, "Lattigo plaintext modulus differs from the recorded one")
		}
		x.slots, x.t = x.pF.MaxSlots(), c.t
		x.encF = bfv.NewEncoder(x.pF)
		x.evF = bfv.NewEvaluator(x.pF, evk)
	}
	x.encr = rlwe.NewEncryptor(x.params, x.pk)
	x.decr = rlwe.NewDecryptor(x.params, x.sk)
}

func (x *ctx) setGaloisKey(gk *rlwe.GaloisKey) {
	evk := rlwe.NewMemEvaluationKeySet(x.rlk, gk)
	switch x.scheme {
	case "CKKS":
		x.evC = x.evC.WithKey(evk)
	case "BGV":
		x.evB = x.evB.WithKey(evk)
	default:
		x.evF = x.evF.WithKey(evk)
	}
}

// ---------- inputs ----------
var rng = rand.New(rand.NewSource(12345))

func (x *ctx) encode(v []float64) *rlwe.Plaintext {
	lvl := x.rp.MaxLevel()
	switch x.scheme {
	case "CKKS":
		pt := ckks.NewPlaintext(x.pC, lvl)
		must(x.encC.Encode(v, pt))
		return pt
	case "BGV":
		pt := bgv.NewPlaintext(x.pB, lvl)
		must(x.encB.Encode(toU64(v, x.t), pt))
		return pt
	default:
		pt := bfv.NewPlaintext(x.pF, lvl)
		must(x.encF.Encode(toU64(v, x.t), pt))
		return pt
	}
}
func toU64(v []float64, t uint64) []uint64 {
	w := make([]uint64, len(v))
	for i, f := range v {
		w[i] = uint64((int64(math.Round(f))%int64(t) + int64(t)) % int64(t))
	}
	return w
}

type fresh struct {
	ct *rlwe.Ciphertext
	x  []float64
}

func (x *ctx) freshCt() fresh {
	v := make([]float64, x.slots)
	for i := range v {
		if x.ckks {
			v[i] = 2*rng.Float64() - 1
		} else {
			v[i] = float64(rng.Int63() % 2)
		}
	}
	ct, err := x.encr.EncryptNew(x.encode(v))
	must(err)
	return fresh{ct, v}
}

// ---------- correctness ----------
func (x *ctx) decodePt(pt *rlwe.Plaintext) []float64 {
	out := make([]float64, x.slots)
	switch x.scheme {
	case "CKKS":
		must(x.encC.Decode(pt, out))
	case "BGV":
		w := make([]uint64, x.slots)
		must(x.encB.Decode(pt, w))
		for i := range w {
			out[i] = float64(w[i])
		}
	default:
		w := make([]uint64, x.slots)
		must(x.encF.Decode(pt, w))
		for i := range w {
			out[i] = float64(w[i])
		}
	}
	return out
}
func (x *ctx) errorOf(got, want []float64) float64 {
	w := 0.0
	for i := range want {
		if x.ckks {
			w = math.Max(w, math.Abs(got[i]-want[i])/math.Max(1, math.Abs(want[i])))
		} else {
			t := int64(x.t)
			g := (int64(math.Round(got[i]))%t + t) % t
			e := (int64(math.Round(want[i]))%t + t) % t
			if g != e {
				w++
			}
		}
	}
	return w
}
func (x *ctx) checkCt(ct *rlwe.Ciphertext, want []float64) float64 {
	return x.errorOf(x.decodePt(x.decr.DecryptNew(ct)), want)
}
func (x *ctx) passes(e float64) bool {
	if x.ckks {
		return e < ckksThreshold
	}
	return e == 0
}

// rotation by +1: slot i receives slot i+1 (CKKS one vector of N/2; BFV/BGV
// two rows of N/2 each rotated cyclically)
func (x *ctx) rotated(v []float64) []float64 {
	e := make([]float64, len(v))
	row := len(v)
	if !x.ckks {
		row = len(v) / 2
	}
	for r := 0; r < len(v); r += row {
		for i := 0; i < row; i++ {
			e[r+i] = v[r+(i+1)%row]
		}
	}
	return e
}

// ---------- evaluator dispatch ----------
func (x *ctx) add(a, b, out *rlwe.Ciphertext) error {
	switch x.scheme {
	case "CKKS":
		return x.evC.Add(a, b, out)
	case "BGV":
		return x.evB.Add(a, b, out)
	}
	return x.evF.Add(a, b, out)
}
func (x *ctx) mul(a, b, out *rlwe.Ciphertext) error {
	switch x.scheme {
	case "CKKS":
		return x.evC.Mul(a, b, out)
	case "BGV":
		return x.evB.Mul(a, b, out)
	}
	return x.evF.Mul(a, b, out)
}
func (x *ctx) relin(a, out *rlwe.Ciphertext) error {
	switch x.scheme {
	case "CKKS":
		return x.evC.Relinearize(a, out)
	case "BGV":
		return x.evB.Relinearize(a, out)
	}
	return x.evF.Relinearize(a, out)
}
func (x *ctx) rotate(a, out *rlwe.Ciphertext) error {
	switch x.scheme {
	case "CKKS":
		return x.evC.Rotate(a, 1, out)
	case "BGV":
		return x.evB.RotateColumns(a, 1, out)
	}
	return x.evF.RotateColumns(a, 1, out)
}
func (x *ctx) rescale(a, out *rlwe.Ciphertext) error {
	switch x.scheme {
	case "CKKS":
		return x.evC.Rescale(a, out)
	case "BGV":
		return x.evB.Rescale(a, out)
	}
	return nil // BFV: no rescaling
}
func (x *ctx) galoisElement() uint64 {
	if x.ckks {
		return x.pC.GaloisElementForRotation(1)
	}
	if x.scheme == "BGV" {
		return x.pB.GaloisElementForColRotation(1)
	}
	return x.pF.GaloisElementForColRotation(1)
}

// ---------- timed operations ----------
type result struct {
	ms     float64
	ct     *rlwe.Ciphertext
	expect []float64
	extra  func() float64
	keys   *ctx
}

func since(t0 time.Time) float64 { return float64(time.Since(t0).Nanoseconds()) / 1e6 }

func timeKeygen(a args, c config) result {
	runtime.GC()
	t0 := time.Now()
	k := makeKeys(a, c)
	ms := since(t0)
	finish(k, c)
	f := k.freshCt()
	return result{ms: ms, ct: f.ct, expect: f.x, keys: k}
}

func timeEncrypt(x *ctx, a args) result {
	v := make([]float64, x.slots)
	for i := range v {
		if x.ckks {
			v[i] = 0.5
		} else {
			v[i] = 1
		}
	}
	pts := make([]*rlwe.Plaintext, a.inner)
	cts := make([]*rlwe.Ciphertext, a.inner)
	for i := range pts {
		pts[i] = x.encode(v)
		cts[i] = rlwe.NewCiphertext(x.params, 1, x.rp.MaxLevel())
	}
	runtime.GC()
	t0 := time.Now()
	for i := 0; i < a.inner; i++ {
		must(x.encr.Encrypt(pts[i], cts[i]))
	}
	return result{ms: since(t0) / float64(a.inner), ct: cts[a.inner-1], expect: v}
}

func timeDecrypt(x *ctx, a args, full bool) result {
	in := make([]fresh, a.inner)
	pts := make([]*rlwe.Plaintext, a.inner)
	for i := range in {
		in[i] = x.freshCt()
		pts[i] = rlwe.NewPlaintext(x.params, x.rp.MaxLevel())
	}
	var dec []float64
	runtime.GC()
	t0 := time.Now()
	if full {
		for i := 0; i < a.inner; i++ {
			x.decr.Decrypt(in[i].ct, pts[i])
			dec = x.decodePt(pts[i])
		}
	} else {
		for i := 0; i < a.inner; i++ {
			x.decr.Decrypt(in[i].ct, pts[i])
		}
	}
	ms := since(t0) / float64(a.inner)
	last := in[a.inner-1]
	r := result{ms: ms, ct: last.ct, expect: last.x}
	pt := pts[a.inner-1]
	if full {
		r.extra = func() float64 { return x.errorOf(dec, last.x) }
	} else {
		// the plaintext computed at this boundary must itself decode to the input
		r.extra = func() float64 { return x.errorOf(x.decodePt(pt), last.x) }
	}
	return r
}

func timeBinary(x *ctx, a args) result {
	xs := make([]fresh, a.inner)
	ys := make([]fresh, a.inner)
	outs := make([]*rlwe.Ciphertext, a.inner)
	for i := range xs {
		xs[i], ys[i] = x.freshCt(), x.freshCt()
		switch a.op {
		case "multiply":
			outs[i] = rlwe.NewCiphertext(x.params, 2, x.rp.MaxLevel())
		case "add":
			// output pre-allocated as a copy of the first input (untimed), so
			// that it carries the inputs' metadata (scale, NTT flag). Observed
			// 21 Nov 2026: BFV/BGV Add into a blank NewCiphertext failed the
			// check (wrong slots); CKKS did not.
			outs[i] = xs[i].ct.CopyNew()
		default:
			outs[i] = rlwe.NewCiphertext(x.params, 1, x.rp.MaxLevel())
		}
	}
	prods := make([]*rlwe.Ciphertext, 0)
	if a.op == "relinearize" { // untimed setup step, as in bench_seal
		for i := range xs {
			p := rlwe.NewCiphertext(x.params, 2, x.rp.MaxLevel())
			must(x.mul(xs[i].ct, ys[i].ct, p))
			prods = append(prods, p)
		}
	}
	runtime.GC()
	t0 := time.Now()
	switch a.op {
	case "add":
		for i := 0; i < a.inner; i++ {
			must(x.add(xs[i].ct, ys[i].ct, outs[i]))
		}
	case "multiply":
		for i := 0; i < a.inner; i++ {
			must(x.mul(xs[i].ct, ys[i].ct, outs[i]))
		}
	default:
		for i := 0; i < a.inner; i++ {
			must(x.relin(prods[i], outs[i]))
		}
	}
	ms := since(t0) / float64(a.inner)
	n := a.inner - 1
	e := make([]float64, x.slots)
	for i := range e {
		if a.op == "add" {
			e[i] = xs[n].x[i] + ys[n].x[i]
		} else {
			e[i] = xs[n].x[i] * ys[n].x[i]
		}
	}
	return result{ms: ms, ct: outs[n], expect: e}
}

func timeRotate(x *ctx) result {
	in := x.freshCt() // setup before t0, one rotation per repetition
	out := rlwe.NewCiphertext(x.params, 1, x.rp.MaxLevel())
	runtime.GC()
	t0 := time.Now()
	must(x.rotate(in.ct, out))
	return result{ms: since(t0), ct: out, expect: x.rotated(in.x)}
}

// ---------- probe: what Lattigo builds, and a depth test ----------
func probe(a args, c config) {
	x := makeKeys(a, c)
	finish(x, c)
	fmt.Println("scheme,N,category,q_primes,p_primes,log2QP,xs,xe,max_level,slots,plaintext_modulus,log2_scale,levels")
	acc := x.freshCt()
	lv := fmt.Sprintf("fresh:err=%g", x.checkCt(acc.ct, acc.x))
	if x.ckks {
		lv += fmt.Sprintf(",prec=%.2f", -math.Log2(x.checkCt(acc.ct, acc.x)))
	}
	cur, v := acc.ct, acc.x
	for d := 1; d <= 3; d++ {
		y := x.freshCt()
		if y.ct.Level() > cur.Level() {
			x.dropTo(y.ct, cur.Level())
		}
		p := rlwe.NewCiphertext(x.params, 2, cur.Level())
		err := x.mul(cur, y.ct, p)
		r := rlwe.NewCiphertext(x.params, 1, cur.Level())
		if err == nil {
			err = x.relin(p, r)
		}
		if err == nil && x.scheme != "BFV" && r.Level() > 0 {
			o := rlwe.NewCiphertext(x.params, 1, r.Level()-1)
			err = x.rescale(r, o)
			r = o
		}
		if err != nil {
			lv += fmt.Sprintf(" | L%d:error %v", d, err)
			break
		}
		for i := range v {
			v[i] *= y.x[i]
		}
		e := x.checkCt(r, v)
		lv += fmt.Sprintf(" | L%d:level=%d,err=%g", d, r.Level(), e)
		if x.ckks {
			lv += fmt.Sprintf(",prec=%.2f", -math.Log2(math.Max(e, 1e-300)))
		}
		if x.passes(e) {
			lv += ",OK"
		} else {
			lv += ",FAIL"
		}
		cur = r
	}
	join := func(v []uint64) string {
		s := make([]string, len(v))
		for i, q := range v {
			s[i] = strconv.FormatUint(q, 10)
		}
		return strings.Join(s, " ")
	}
	ls := ""
	if x.ckks {
		ls = strconv.Itoa(x.pC.LogDefaultScale())
	}
	fmt.Printf("%s,%d,%d,%s,%s,%.2f,%v,%v,%d,%d,%d,%s,\"%s\"\n", a.scheme, a.n, a.cat, join(x.rp.Q()), join(x.rp.P()),
		x.rp.LogQP(), x.rp.Xs(), x.rp.Xe(), x.rp.MaxLevel(), x.slots, x.t, ls, lv)
}

func (x *ctx) dropTo(ct *rlwe.Ciphertext, level int) {
	switch x.scheme {
	case "CKKS":
		x.evC.DropLevel(ct, ct.Level()-level)
	case "BGV":
		x.evB.DropLevel(ct, ct.Level()-level)
	default:
		x.evF.DropLevel(ct, ct.Level()-level)
	}
}

// ---------- output ----------
func writeAtomically(path, content string) {
	tmp := path + ".tmp"
	must(os.WriteFile(tmp, []byte(content), 0o644))
	must(os.Rename(tmp, path))
}

func main() {
	runtime.GOMAXPROCS(1)
	a := parseArgs()
	c := loadConfig(a)
	if a.op == "probe" {
		probe(a, c)
		return
	}
	os.Remove(a.out)
	os.Remove(a.check)
	var x *ctx
	gkMs, gkBytes := 0.0, 0
	if a.op != "keygen" {
		x = makeKeys(a, c)
		finish(x, c)
		if a.op == "rotate" {
			t0 := time.Now()
			gk := rlwe.NewKeyGenerator(x.params).GenGaloisKeyNew(x.galoisElement(), x.sk)
			gkMs = since(t0)
			gkBytes = gk.BinarySize()
			x.setGaloisKey(gk)
		}
	}
	var out, chk strings.Builder
	if a.op == "rotate" {
		out.WriteString("library,scheme,N,category,operation,galois_keygen_ms,galois_keys_size_bytes,iteration,latency_ms,status\n")
	} else {
		out.WriteString("library,scheme,N,category,operation,batch_size,iteration,latency_ms,status\n")
	}
	chk.WriteString("library,scheme,N,category,operation,iteration,norm_error,correctness\n")
	ident := fmt.Sprintf("Lattigo,%s,%d,%d,%s,", a.scheme, a.n, a.cat, a.op)
	total := a.warmup + a.reps
	for i := 0; i < total; i++ {
		var r result
		switch a.op {
		case "keygen":
			r = timeKeygen(a, c)
		case "encrypt":
			r = timeEncrypt(x, a)
		case "decrypt":
			r = timeDecrypt(x, a, false)
		case "decrypt_full":
			r = timeDecrypt(x, a, true)
		case "rotate":
			r = timeRotate(x)
		default:
			r = timeBinary(x, a)
		}
		k := x
		if a.op == "keygen" {
			k = r.keys
		}
		if i == a.inj { // TESTS ONLY
			for j := range r.expect {
				r.expect[j] += 1
			}
		}
		var e float64
		if a.op == "multiply" {
			// a degree-2 result is checked after relinearization (outside the timing)
			rl := rlwe.NewCiphertext(k.params, 1, r.ct.Level())
			must(k.relin(r.ct, rl))
			e = k.checkCt(rl, r.expect)
		} else {
			e = k.checkCt(r.ct, r.expect)
		}
		if r.extra != nil && k.passes(e) {
			e = math.Max(e, r.extra())
		}
		ok := k.passes(e)
		status := "measured"
		if i < a.warmup {
			status = "warmup"
		}
		if a.op == "rotate" {
			fmt.Fprintf(&out, "%s%f,%d,%d,%g,%s\n", ident, gkMs, gkBytes, i, r.ms, status)
		} else {
			fmt.Fprintf(&out, "%s1,%d,%g,%s\n", ident, i, r.ms, status)
		}
		verdict := "correct"
		if !ok {
			verdict = "INCORRECT"
		}
		fmt.Fprintf(&chk, "%s%d,%g,%s\n", ident, i, e, verdict)
		if !ok {
			writeAtomically(a.out+".invalid", out.String()+fmt.Sprintf("# INVALID: correctness check failed at iteration %d\n", i))
			writeAtomically(a.check+".invalid", chk.String())
			fmt.Fprintf(os.Stderr, "FAILED: correctness check at iteration %d (error %g) -- no output written\n", i, e)
			os.Exit(3)
		}
	}
	writeAtomically(a.check, chk.String())
	writeAtomically(a.out, out.String())
	fmt.Printf("OK: wrote %d rows to %s (all %d checks correct)\n", total, a.out, total)
}
