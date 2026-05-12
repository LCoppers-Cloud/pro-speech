# Pacing equations

The brain has one job: **keep the prompt buffer ahead of the speaker without ever
running it empty**, and **make sure the TTS audio lands just before the speaker
needs it**. Everything else is plumbing.

## Variables

| Symbol | Meaning | Default |
|---|---|---|
| `ℓ_claude` | Time-to-first-token from Claude Haiku 4.5 | 0.60 s |
| `ℓ_tts` | First-audio latency of `AVSpeechSynthesizer` | 0.15 s |
| `ℓ_safety` | Safety margin for jitter / BT SCO variance | 0.30 s |
| `L` | Total lookahead = `ℓ_claude + ℓ_tts + ℓ_safety` | 1.05 s |
| `σ/μ` | Coefficient of variation of within-session WPM | 0.15 |
| `z` | Buffer headroom z-score (1.28 ≈ p90) | 1.28 |
| `k_σ` | `1 + z·σ/μ` | ≈ 1.19 |

## Rate tracking

Track *syllables per second*, not WPM. Per-word rate has huge variance ("a" vs
"responsibility"); syllable rate is far more stable
(Goldman-Eisler 1968; Yuan, Liberman & Cieri 2006).

Two EWMAs on per-word instantaneous rate `r_i = syl_i / Δt_i`:

```
ŝ_fast ← α_f · r_i + (1 − α_f) · ŝ_fast,   α_f = 1 − exp(−Δt_i / τ_f),  τ_f = 2 s
ŝ_slow ← α_s · r_i + (1 − α_s) · ŝ_slow,   τ_s = 15 s
```

`ŝ_fast` drives live pacing decisions. `ŝ_slow` is persisted to the speaker
profile across sessions. Single-word outliers are clipped to `[0.3, 1.7] · ŝ_slow`
before the update so a coughed-out word doesn't crash the estimate.

Convert to display WPM with `WPM = 60 · ŝ_fast / (mean syl/word)`.

## Buffer-ahead policy

The minimum number of unspoken buffered words at any moment:

```
N_min = ⌈ WPM / 60 · L · k_σ ⌉
```

At 150 WPM with default L = 1.05 s, k_σ ≈ 1.19:
`N_min = ⌈ 2.5 · 1.05 · 1.19 ⌉ = ⌈ 3.13 ⌉ = 4` words.

At 200 WPM: 5 words. At 100 WPM: 3 words. Matches the speaker's intuition that
the prompt should be ~3 words ahead at typical pace.

## Chunk size

Each Claude request fetches:

```
N_chunk = clip( 2·N_min + ⌈WPM/60 · 2⌉,  8,  15 )
```

Floor 8 prevents pointless round-trips when the speaker is slow; ceiling 15 caps
wasted generation when the speaker goes off-script and the buffer is discarded.

## Trigger condition

Anticipate the round-trip itself — the speaker keeps eating the buffer while
Claude is generating:

```
trigger when:  wordsRemaining ≤ N_min + ⌈WPM/60 · ℓ_claude⌉
```

## TTS pacing

`AVSpeechSynthesizer.rate` is non-linear and undocumented. Empirically, at the
default rate 0.5 the synthesizer speaks at ~175 WPM in `en-US`. A linear
approximation in the working range:

```
rate ≈ 0.5 · WPM / 175,   clamped to [0.30, 0.65]
```

Target TTS WPM = **1.10 × user WPM**. The slight overspeed lands each whispered
word ~10% of the chunk-duration before the highlight reaches it — about 300 ms
of reaction time at typical pace, which empirically is enough for a speaker to
hear the cue and produce the word.

Cap at user-WPM ≤ 210 to avoid the comprehension cliff for whispered TTS
(Rodero 2016).

## Edge cases

- **Long pause (> 1.5 s):** freeze the highlight, pause TTS at the word boundary,
  do not update the EWMA. A pause is not a speech-rate signal.
- **Word repetition (< 600 ms):** do not advance the highlight on `"very, very"`.
- **Off-script:** if the aligner misses 3 consecutive words, discard the buffer,
  cancel TTS, and request a fresh chunk seeded with the new direction. Better a
  short silence than a wrong prompt.
- **Overflow** (speaker faster than predicted): jump the highlight forward, drop
  the in-flight TTS utterance, log for `ℓ_tts` recalibration.
- **Cold start:** use the persisted speaker mean if available, else 140 WPM,
  σ = 25. After ~5 words the live EWMA dominates the prior.

## What's calibrated vs. A/B-tested

Analytically derivable from the spec:
- `N_min`, `N_chunk`, trigger threshold given fixed `ℓ_claude`, `ℓ_tts`, `ℓ_safety`.

Needs real-device A/B testing:
- `τ_fast` (responsiveness vs. jitter trade-off).
- `β = 1.10` TTS lead factor — depends on whisper voice intelligibility.
- The off-script threshold (3 consecutive misses).
- The exact `rate → WPM` map per voice / locale.
