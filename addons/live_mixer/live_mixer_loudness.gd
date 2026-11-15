@tool
extends RefCounted
## Loudness meter following ITU-R BS.1770-4 / EBU R128, for stereo.
##
## Feed it raw frames with push(). It reports:
## - momentary: last 400 ms
## - short_term: last 3 s
## - integrated: since the last reset(), gated (-70 LUFS absolute, then
##   -10 LU relative), the number loudness targets are written against
## - true_peak: highest inter-sample peak since reset(), in dBTP, found by
##   4x oversampling
##
## All values are LUFS (dBTP for true peak), or -INF when there's nothing
## to report yet.
##
## Integrated uses a histogram of 0.1 LU bins holding the exact block
## energies, so it costs the same after an hour as after a second.

const ABSOLUTE_GATE_LUFS: float = -70.0
const RELATIVE_GATE_LU: float = -10.0
const SUB_BLOCK_SEC: float = 0.1
const MOMENTARY_SUB_BLOCKS: int = 4
const SHORT_TERM_SUB_BLOCKS: int = 30
const HIST_MIN_LUFS: float = -70.0
const HIST_MAX_LUFS: float = 10.0
const HIST_STEP: float = 0.1
## True peak is only checked around samples above this, since an
## inter-sample peak can't be far above its neighbours. Keeps the 4x
## oversampling cost near zero in normal play.
const TRUE_PEAK_CHECK_LINEAR: float = 0.25
const OVERSAMPLE: int = 4
const FIR_TAPS_PER_PHASE: int = 12

var momentary: float = -INF
var short_term: float = -INF
var integrated: float = -INF
var true_peak: float = -INF

var _rate: float = 0.0
var _sub_block_frames: int = 0
# K-weighting: two biquads per channel. [b0, b1, b2, a1, a2] each.
var _shelf: PackedFloat64Array = PackedFloat64Array()
var _highpass: PackedFloat64Array = PackedFloat64Array()
# Filter state, per channel: shelf z1, z2, highpass z1, z2.
var _state_l: PackedFloat64Array = PackedFloat64Array([0.0, 0.0, 0.0, 0.0])
var _state_r: PackedFloat64Array = PackedFloat64Array([0.0, 0.0, 0.0, 0.0])
var _acc: float = 0.0
var _acc_frames: int = 0
## Ring of the last SHORT_TERM_SUB_BLOCKS sub-block mean energies.
var _ring: PackedFloat64Array = PackedFloat64Array()
var _ring_pos: int = 0
var _ring_filled: int = 0
var _hist_energy: PackedFloat64Array = PackedFloat64Array()
var _hist_count: PackedInt32Array = PackedInt32Array()
var _integrating: bool = true
## Linear gain applied to everything pushed, e.g. a fader after the capture
## point. Applied on the way in, so a gain change only affects what's
## measured from then on, as it would at the real output.
var _input_gain: float = 1.0
# Polyphase interpolation filter for true peak, and recent input history.
var _fir: PackedFloat64Array = PackedFloat64Array()
var _hist_l: PackedFloat64Array = PackedFloat64Array()
var _hist_r: PackedFloat64Array = PackedFloat64Array()
var _hist_pos: int = 0


func _init() -> void:
	_ring.resize(SHORT_TERM_SUB_BLOCKS)
	var bins: int = int(round((HIST_MAX_LUFS - HIST_MIN_LUFS) / HIST_STEP))
	_hist_energy.resize(bins)
	_hist_count.resize(bins)
	_build_fir()
	_hist_l.resize(FIR_TAPS_PER_PHASE)
	_hist_r.resize(FIR_TAPS_PER_PHASE)


## Sets the sample rate. Rebuilds the filters and clears everything if it
## changed.
func set_rate(rate: float) -> void:
	if is_equal_approx(rate, _rate):
		return
	_rate = rate
	_sub_block_frames = int(round(rate * SUB_BLOCK_SEC))
	_build_k_weighting(rate)
	_clear_filters()
	reset()


func get_rate() -> float:
	return _rate


## While false, momentary and short-term keep updating but nothing is added
## to the integrated value or true peak (e.g. while a reference noise
## plays).
func set_integrating(on: bool) -> void:
	_integrating = on


func set_input_gain_db(gain_db: float) -> void:
	_input_gain = db_to_linear(gain_db)


## Starts a new measurement: clears integrated, true peak and the windows.
## The filters' memory of the last few samples is kept: it's real audio,
## and wiping it would look like a jump from silence and fake a true peak.
func reset() -> void:
	_acc = 0.0
	_acc_frames = 0
	_ring.fill(0.0)
	_ring_pos = 0
	_ring_filled = 0
	_hist_energy.fill(0.0)
	_hist_count.fill(0)
	momentary = -INF
	short_term = -INF
	integrated = -INF
	true_peak = -INF


## Feeds stereo frames (x = left, y = right), linear, as captured.
func push(frames: PackedVector2Array) -> void:
	if _rate <= 0.0:
		push_error("Live Mixer loudness: set_rate() must be called before push().")
		return
	var s0: float = _shelf[0]
	var s1: float = _shelf[1]
	var s2: float = _shelf[2]
	var s3: float = _shelf[3]
	var s4: float = _shelf[4]
	var h0: float = _highpass[0]
	var h1: float = _highpass[1]
	var h2: float = _highpass[2]
	var h3: float = _highpass[3]
	var h4: float = _highpass[4]
	var l1: float = _state_l[0]
	var l2: float = _state_l[1]
	var l3: float = _state_l[2]
	var l4: float = _state_l[3]
	var r1: float = _state_r[0]
	var r2: float = _state_r[1]
	var r3: float = _state_r[2]
	var r4: float = _state_r[3]
	var acc: float = _acc
	var acc_frames: int = _acc_frames
	var peak_check: bool = _integrating
	var gain: float = _input_gain

	for frame: Vector2 in frames:
		var xl: float = frame.x * gain
		var xr: float = frame.y * gain

		if peak_check:
			_push_true_peak(xl, xr)

		# Transposed direct form II, shelf then high-pass, left.
		var yl: float = s0 * xl + l1
		l1 = s1 * xl - s3 * yl + l2
		l2 = s2 * xl - s4 * yl
		var zl: float = h0 * yl + l3
		l3 = h1 * yl - h3 * zl + l4
		l4 = h2 * yl - h4 * zl
		# Right.
		var yr: float = s0 * xr + r1
		r1 = s1 * xr - s3 * yr + r2
		r2 = s2 * xr - s4 * yr
		var zr: float = h0 * yr + r3
		r3 = h1 * yr - h3 * zr + r4
		r4 = h2 * yr - h4 * zr

		acc += zl * zl + zr * zr
		acc_frames += 1
		if acc_frames >= _sub_block_frames:
			_finish_sub_block(acc / acc_frames)
			acc = 0.0
			acc_frames = 0

	_state_l[0] = l1
	_state_l[1] = l2
	_state_l[2] = l3
	_state_l[3] = l4
	_state_r[0] = r1
	_state_r[1] = r2
	_state_r[2] = r3
	_state_r[3] = r4
	_acc = acc
	_acc_frames = acc_frames


## Feeds silence, for gaps where the game sent nothing (AudioServer stops
## processing a bus that's gone quiet, so its capture goes empty).
func push_silence(frame_count: int) -> void:
	var silent: PackedVector2Array = PackedVector2Array()
	silent.resize(frame_count)
	push(silent)


## Only for a sample-rate change, when the old filter memory means nothing.
func _clear_filters() -> void:
	for i: int in 4:
		_state_l[i] = 0.0
		_state_r[i] = 0.0
	_hist_l.fill(0.0)
	_hist_r.fill(0.0)


func _finish_sub_block(energy: float) -> void:
	_ring[_ring_pos] = energy
	_ring_pos = (_ring_pos + 1) % SHORT_TERM_SUB_BLOCKS
	_ring_filled = mini(_ring_filled + 1, SHORT_TERM_SUB_BLOCKS)

	var m_energy: float = _ring_mean(MOMENTARY_SUB_BLOCKS)
	momentary = _energy_to_lufs(m_energy) if _ring_filled >= MOMENTARY_SUB_BLOCKS else -INF
	short_term = _energy_to_lufs(_ring_mean(SHORT_TERM_SUB_BLOCKS)) if _ring_filled >= SHORT_TERM_SUB_BLOCKS else -INF

	# Each finished 100 ms step completes one 400 ms gating block (75 %
	# overlap), whose energy is the momentary energy.
	if _integrating and _ring_filled >= MOMENTARY_SUB_BLOCKS:
		_add_gating_block(m_energy)


func _ring_mean(count: int) -> float:
	var n: int = mini(count, _ring_filled)
	if n == 0:
		return 0.0
	var total: float = 0.0
	for i: int in n:
		total += _ring[(_ring_pos - 1 - i + SHORT_TERM_SUB_BLOCKS) % SHORT_TERM_SUB_BLOCKS]
	return total / n


func _add_gating_block(energy: float) -> void:
	var lufs: float = _energy_to_lufs(energy)
	if lufs <= ABSOLUTE_GATE_LUFS:
		return
	var bin: int = clampi(int((lufs - HIST_MIN_LUFS) / HIST_STEP), 0, _hist_count.size() - 1)
	_hist_energy[bin] += energy
	_hist_count[bin] += 1
	_update_integrated()


func _update_integrated() -> void:
	var total: float = 0.0
	var count: int = 0
	for i: int in _hist_count.size():
		total += _hist_energy[i]
		count += _hist_count[i]
	if count == 0:
		integrated = -INF
		return
	var gate: float = _energy_to_lufs(total / count) + RELATIVE_GATE_LU
	var gate_bin: int = int((gate - HIST_MIN_LUFS) / HIST_STEP)
	total = 0.0
	count = 0
	for i: int in range(maxi(gate_bin, 0), _hist_count.size()):
		total += _hist_energy[i]
		count += _hist_count[i]
	integrated = _energy_to_lufs(total / count) if count > 0 else -INF


func _energy_to_lufs(energy: float) -> float:
	if energy <= 0.0:
		return -INF
	return -0.691 + 10.0 * log(energy) / log(10.0)


## K-weighting filter coefficients for any sample rate, from the analogue
## prototypes behind BS.1770's 48 kHz tables (as in libebur128).
func _build_k_weighting(rate: float) -> void:
	var f0: float = 1681.974450955533
	var gain_db: float = 3.999843853973347
	var q: float = 0.7071752369554196
	var k: float = tan(PI * f0 / rate)
	var vh: float = pow(10.0, gain_db / 20.0)
	var vb: float = pow(vh, 0.4996667741545416)
	var a0: float = 1.0 + k / q + k * k
	_shelf = PackedFloat64Array([
		(vh + vb * k / q + k * k) / a0,
		2.0 * (k * k - vh) / a0,
		(vh - vb * k / q + k * k) / a0,
		2.0 * (k * k - 1.0) / a0,
		(1.0 - k / q + k * k) / a0,
	])

	f0 = 38.13547087602444
	q = 0.5003270373238773
	k = tan(PI * f0 / rate)
	a0 = 1.0 + k / q + k * k
	_highpass = PackedFloat64Array([
		1.0,
		-2.0,
		1.0,
		2.0 * (k * k - 1.0) / a0,
		(1.0 - k / q + k * k) / a0,
	])


## 48-tap windowed-sinc interpolator split into 4 phases of 12 taps, the
## same shape as the example filter in BS.1770 Annex 2.
func _build_fir() -> void:
	var taps: int = OVERSAMPLE * FIR_TAPS_PER_PHASE
	var full: PackedFloat64Array = PackedFloat64Array()
	full.resize(taps)
	var centre: float = (taps - 1) * 0.5
	for n: int in taps:
		var t: float = (n - centre) / OVERSAMPLE
		var sinc: float = 1.0 if is_zero_approx(t) else sin(PI * t) / (PI * t)
		var window: float = 0.5 - 0.5 * cos(TAU * (n + 0.5) / taps)
		full[n] = sinc * window
	# Normalise each phase to unity DC gain.
	_fir.resize(taps)
	for phase: int in OVERSAMPLE:
		var sum: float = 0.0
		for j: int in FIR_TAPS_PER_PHASE:
			sum += full[j * OVERSAMPLE + phase]
		for j: int in FIR_TAPS_PER_PHASE:
			_fir[phase * FIR_TAPS_PER_PHASE + j] = full[j * OVERSAMPLE + phase] / sum


func _push_true_peak(xl: float, xr: float) -> void:
	_hist_l[_hist_pos] = xl
	_hist_r[_hist_pos] = xr
	_hist_pos = (_hist_pos + 1) % FIR_TAPS_PER_PHASE

	var sample_peak: float = maxf(absf(xl), absf(xr))
	var level: float = linear_to_db(sample_peak) if sample_peak > 0.0 else -INF
	if level > true_peak:
		true_peak = level

	# Only oversample when the sample in the middle of the window is loud.
	var mid: int = (_hist_pos + FIR_TAPS_PER_PHASE / 2) % FIR_TAPS_PER_PHASE
	if maxf(absf(_hist_l[mid]), absf(_hist_r[mid])) < TRUE_PEAK_CHECK_LINEAR:
		return
	for phase: int in OVERSAMPLE:
		var acc_l: float = 0.0
		var acc_r: float = 0.0
		for j: int in FIR_TAPS_PER_PHASE:
			var idx: int = (_hist_pos - 1 - j + FIR_TAPS_PER_PHASE) % FIR_TAPS_PER_PHASE
			var c: float = _fir[phase * FIR_TAPS_PER_PHASE + j]
			acc_l += c * _hist_l[idx]
			acc_r += c * _hist_r[idx]
		var p: float = maxf(absf(acc_l), absf(acc_r))
		if p > 0.0:
			var db: float = linear_to_db(p)
			if db > true_peak:
				true_peak = db
