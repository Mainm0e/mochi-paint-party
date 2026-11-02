"""Mochi Paint Party's background music: six original, upbeat 'sunny resort pop' loops, one per place.

Everything is synthesized from sine/noise math (numpy only) and composed here: chord progressions, a short
melodic motif per song that is re-voiced over each chord, and a groove (drums, bass, keys, pads, lead).
Each loop is rendered with a tail that is folded back onto its start, so it repeats seamlessly.

Run with any Python that has numpy, e.g. Blender's:
    blender --background --factory-startup --python tools/make_music.py -- godot/assets/audio
"""
import os
import sys
import wave

import numpy as np

OUT = sys.argv[sys.argv.index("--") + 1] if "--" in sys.argv else os.path.join(os.path.dirname(__file__), "..", "godot", "assets", "audio")
OUT = os.path.abspath(OUT)
os.makedirs(OUT, exist_ok=True)
SR = 44100
rng = np.random.default_rng(11)


def hz(m):
    return 440.0 * 2 ** ((m - 69) / 12)


def tt(dur):
    return np.arange(int(dur * SR)) / SR


def adsr(n, a=0.005, d=0.1, s=0.6, r=0.08):
    """Attack/decay/sustain over n samples, with a release ramp at the end."""
    t = np.arange(n) / SR
    dur = n / SR
    e = np.where(t < a, t / max(a, 1e-4), s + (1 - s) * np.exp(-(t - a) / max(d, 1e-4)))
    e *= np.clip((dur - t) / max(r, 1e-4), 0, 1)
    return e


def onepole(x, cutoff):
    """One-pole low-pass. A Python loop, so it's only used on short drum samples."""
    a = np.exp(-2 * np.pi * cutoff / SR)
    y = np.empty_like(x)
    acc = 0.0
    for i, v in enumerate(x):
        acc = (1 - a) * v + a * acc
        y[i] = acc
    return y


# ------------------------------------------------------------------ instruments (all original synthesis)
def epiano(f, dur, vel=1.0):
    """Bell-ish electric piano: a little FM, bright attack that mellows."""
    t = tt(dur)
    mod = (1.4 * np.exp(-t * 4.0) + 0.25) * np.sin(2 * np.pi * f * t)
    x = np.sin(2 * np.pi * f * t + mod) + 0.25 * np.sin(2 * np.pi * 2 * f * t) * np.exp(-t * 6)
    return x * adsr(len(t), 0.003, 0.5, 0.25, 0.12) * vel


def bass(f, dur, vel=1.0):
    """Round, plucky synth bass with a touch of growl."""
    t = tt(dur)
    bright = np.exp(-t * 9.0)
    x = sum((1.0 / k) * np.sin(2 * np.pi * f * k * t) * (bright if k > 2 else 1.0) for k in range(1, 7))
    return x * adsr(len(t), 0.004, 0.25, 0.55, 0.05) * vel


def lead(f, dur, vel=1.0, kind="whistle"):
    """The tune. 'whistle': airy flute-whistle; 'square': bright chip lead; 'brass': punchy synth brass."""
    t = tt(dur)
    vib = 1 + 0.006 * np.sin(2 * np.pi * 5.5 * t) * np.clip((t - 0.12) / 0.15, 0, 1)
    ph = 2 * np.pi * f * np.cumsum(vib) / SR
    if kind == "square":
        x = sum(np.sin(k * ph) / k for k in (1, 3, 5, 7, 9)) * 0.8
        env = adsr(len(t), 0.004, 0.2, 0.7, 0.04)
    elif kind == "brass":
        swell = np.clip(t / 0.06, 0, 1)
        x = sum(np.sin(k * ph) / k * (swell ** (k * 0.3)) for k in range(1, 9))
        env = adsr(len(t), 0.03, 0.3, 0.75, 0.06)
    else:
        breath = rng.standard_normal(len(t)) * 0.04 * np.exp(-t * 12)
        x = np.sin(ph) + 0.18 * np.sin(2 * ph) + 0.06 * np.sin(3 * ph) + breath
        env = adsr(len(t), 0.02, 0.3, 0.8, 0.05)
    return x * env * vel


def steel(f, dur, vel=1.0):
    """Steel-drum-ish: a few slightly inharmonic partials with a quick bloom."""
    t = tt(dur)
    x = (np.sin(2 * np.pi * f * t) + 0.5 * np.sin(2 * np.pi * f * 2.0 * t) * np.exp(-t * 3)
         + 0.35 * np.sin(2 * np.pi * f * 3.02 * t) * np.exp(-t * 5) + 0.2 * np.sin(2 * np.pi * f * 4.1 * t) * np.exp(-t * 8))
    return x * adsr(len(t), 0.002, 0.35, 0.2, 0.1) * vel


def bell(f, dur, vel=1.0):
    t = tt(dur)
    x = np.sin(2 * np.pi * f * t) + 0.4 * np.sin(2 * np.pi * f * 2.0 * t) * np.exp(-t * 5) + 0.2 * np.sin(2 * np.pi * f * 3.01 * t) * np.exp(-t * 9)
    return x * adsr(len(t), 0.002, 0.6, 0.0, 0.1) * vel


def pad(freqs, dur, vel=1.0):
    """Soft, slightly detuned string pad."""
    t = tt(dur)
    x = np.zeros_like(t)
    for f in freqs:
        for det in (-0.004, 0.004):
            x += np.sin(2 * np.pi * f * (1 + det) * t) + 0.3 * np.sin(2 * np.pi * 2 * f * (1 + det) * t)
    return x / max(1, len(freqs)) * adsr(len(t), 0.25, 1.0, 0.85, 0.3) * vel


# drums are made once and reused
N_KICK = int(0.32 * SR)
_t = np.arange(N_KICK) / SR
KICK = np.sin(2 * np.pi * np.cumsum(45 + 95 * np.exp(-_t * 30)) / SR) * np.exp(-_t * 9)
N_SN = int(0.22 * SR)
_t = np.arange(N_SN) / SR
_noise = rng.standard_normal(N_SN)
SNARE = 0.55 * np.sin(2 * np.pi * 190 * _t) * np.exp(-_t * 25) + (_noise - onepole(_noise, 1200)) * 0.7 * np.exp(-_t * 18)
N_HAT = int(0.06 * SR)
_noise = rng.standard_normal(N_HAT)
HAT = (_noise - onepole(_noise, 6500)) * np.exp(-np.arange(N_HAT) / SR * 70)
N_OHAT = int(0.25 * SR)
_noise = rng.standard_normal(N_OHAT)
OHAT = (_noise - onepole(_noise, 6000)) * np.exp(-np.arange(N_OHAT) / SR * 12)
N_SHK = int(0.08 * SR)
_noise = rng.standard_normal(N_SHK)
SHAKER = (_noise - onepole(_noise, 4500)) * np.sin(np.pi * np.arange(N_SHK) / N_SHK) ** 2
N_CLAP = int(0.2 * SR)
_noise = rng.standard_normal(N_CLAP)
_t = np.arange(N_CLAP) / SR
CLAP = onepole(_noise, 3000) * (np.exp(-_t * 30) + 0.6 * np.exp(-np.maximum(_t - 0.012, 0) * 30) * (_t > 0.012))

# mix balance: a light, bright mix (sunny pop wants sparkle on top, not a heavy bottom)
KICK *= 0.5
HAT *= 1.9
OHAT *= 1.7
SHAKER *= 1.7
CLAP *= 1.3
BASS_GAIN = 0.24
KEYS_GAIN = 0.32
LEAD_BOOST = 1.6

CHORDS = {
    "maj7": [0, 4, 7, 11], "m7": [0, 3, 7, 10], "7": [0, 4, 7, 10], "add9": [0, 4, 7, 14], "6": [0, 4, 7, 9],
    "m9": [0, 3, 7, 14], "sus": [0, 5, 7, 10], "maj": [0, 4, 7, 12], "m": [0, 3, 7, 12], "dim": [0, 3, 6, 9],
}


# ------------------------------------------------------------------ the song engine
def song(name, bpm, chords, motifs, *, swing=0.0, lead_kind="whistle", lead_oct=72, groove="pop", keys="epiano",
         brass_stabs=False, bells=False, steel_lead=False, pad_gain=0.05, lead_gain=0.17):
    """Render one seamless loop.

    chords: one (root midi, quality) per bar.  motifs: dict of name -> notes [(beat, length, tone)], where tone
    indexes the chord's tones (0-3, +4 per octave) so one motif fits every chord. Bars use motifs in the order
    of the 'plan' entry (a list of motif names, one per bar; None = rest bar)."""
    beat = 60.0 / bpm
    bars = len(chords)
    n = int(bars * 4 * beat * SR)
    tail = int(3.0 * SR)
    out = np.zeros(n + tail)

    def put(sig, at, gain):
        i = int(at * SR)
        if i >= len(out):
            return
        seg = sig[:len(out) - i]
        out[i:i + len(seg)] += seg * gain

    def when(b, pos):  # bar, beat-in-bar -> seconds, with swing on the off-8ths
        frac = pos - int(pos)
        sw = swing * beat * 0.5 if abs(frac - 0.5) < 1e-6 else 0.0
        return (b * 4 + pos) * beat + sw

    plan = motifs["plan"]
    for b, (root, q) in enumerate(chords):
        iv = CHORDS[q]
        tones = [root + i for i in iv]
        # --- drums
        if groove == "pop":
            for k, pos in enumerate((0, 1.5, 2, 2.75)):
                put(KICK, when(b, pos), 0.9 if pos in (0, 2) else 0.55)
            for pos in (1, 3):
                put(SNARE, when(b, pos), 0.45)
                put(CLAP, when(b, pos), 0.18)
            for i in range(8):
                put(HAT, when(b, i * 0.5), 0.10 if i % 2 else 0.14)
            put(OHAT, when(b, 3.5), 0.06)
        elif groove == "swing":
            put(KICK, when(b, 0), 0.8)
            put(KICK, when(b, 2.5), 0.5)
            for pos in (1, 3):
                put(SNARE, when(b, pos), 0.35)
            for pos in (0, 1, 1.5, 2, 3, 3.5):  # ride-ish pattern
                put(HAT, when(b, pos), 0.13)
        elif groove == "bossa":
            for pos in (0, 1.5, 2, 3.5):
                put(KICK, when(b, pos), 0.6)
            for pos in (0.5, 1.5, 2.5, 3.0) if b % 2 == 0 else (0.5, 1.75, 3.0):  # rim clicks
                put(HAT[:int(0.03 * SR)] * 3, when(b, pos), 0.06)
            for i in range(8):
                put(SHAKER, when(b, i * 0.5), 0.07 if i % 2 else 0.1)
        elif groove == "drive":
            for pos in (0, 1, 2, 3):
                put(KICK, when(b, pos), 0.8)
            for pos in (1, 3):
                put(SNARE, when(b, pos), 0.5)
            for i in range(8):
                put(HAT if i % 2 == 0 else OHAT[:int(0.12 * SR)], when(b, i * 0.5), 0.1)
        elif groove == "sparkle":
            put(KICK, when(b, 0), 0.6)
            put(KICK, when(b, 2.5), 0.4)
            put(SNARE, when(b, 2), 0.3)
            for i in range(16):
                put(SHAKER, when(b, i * 0.25), 0.05 if i % 2 else 0.08)
        elif groove == "lounge":
            put(KICK, when(b, 0), 0.6)
            put(KICK, when(b, 2.5), 0.45)
            for pos in (1, 3):
                put(SNARE[:int(0.1 * SR)], when(b, pos), 0.22)
            for i in range(8):
                put(SHAKER, when(b, i * 0.5), 0.07)
        # --- bass: root, fifth, a hop up the octave, an approach note into the next bar
        nxt = chords[(b + 1) % bars][0]
        bass_line = [(0, 0.9, root), (1.5, 0.4, root + 12), (2, 0.9, root + 7), (3, 0.45, root),
                     (3.5, 0.45, nxt - 1 if nxt > root else nxt + 1)]
        if groove == "bossa":
            bass_line = [(0, 1.4, root), (1.5, 0.45, root + 7), (2, 1.4, root + 7), (3.5, 0.45, root)]
        if groove == "drive":
            bass_line = [(i * 0.5, 0.4, root + (12 if i % 4 == 3 else 0)) for i in range(8)]
        for pos, ln, m in bass_line:
            put(bass(hz(m - 12), ln * beat), when(b, pos), BASS_GAIN)
        # --- keys: offbeat chord stabs (pop), or longer comping
        voicing = [hz(t + 12) for t in tones[1:]] + [hz(tones[0] + 24)]
        stabs = (0.5, 1.5, 2.5, 3.5) if groove in ("pop", "drive") else ((0, 1.5, 3) if groove in ("bossa", "lounge") else (0, 2.5))
        for pos in stabs:
            ln = 0.4 if groove in ("pop", "drive") else 1.2
            sig = sum(epiano(f, ln * beat + 0.3) for f in voicing) / len(voicing)
            put(sig, when(b, pos), KEYS_GAIN)
        # --- pad
        put(pad([hz(t + 12) for t in tones[:3]], 4 * beat + 0.4), when(b, 0), pad_gain)
        # --- brass stabs at the end of every other bar
        if brass_stabs and b % 2 == 1:
            for pos in (3, 3.5):
                sig = sum(lead(hz(t + 12), 0.35 * beat, 1.0, "brass") for t in tones[:3]) / 3
                put(sig, when(b, pos), 0.16)
        # --- the tune
        mot = plan[b % len(plan)]
        if mot is not None:
            ext = tones + [t + 12 for t in tones] + [t + 24 for t in tones]
            shift = 12 * round((lead_oct - (tones[0] + 12)) / 12)  # tone 4 (the root, an octave up) sits near lead_oct
            for pos, ln, idx in motifs[mot]:
                m = ext[idx] + shift
                if steel_lead:
                    sig = steel(hz(m), ln * beat + 0.4)
                elif bells:
                    sig = bell(hz(m), ln * beat + 0.6)
                else:
                    sig = lead(hz(m), ln * beat, 1.0, lead_kind)
                put(sig, when(b, pos), lead_gain * LEAD_BOOST)
                if bells or steel_lead:  # a soft echo an octave up
                    put(bell(hz(m + 12), 0.5) if bells else steel(hz(m + 12), 0.4), when(b, pos) + beat * 0.75, lead_gain * 0.18)

    # a little room: a few soft echoes (cheap reverb)
    wet = np.zeros_like(out)
    for delay, g in ((0.031, 0.25), (0.047, 0.2), (0.071, 0.16), (0.11, 0.12), (0.17, 0.08)):
        d = int(delay * SR)
        wet[d:] += out[:-d] * g
    out = out + wet * 0.6
    out[:tail] += out[n:n + tail]  # fold the tail onto the start: seamless loop
    x = out[:n]
    x = np.tanh(x / (np.max(np.abs(x)) + 1e-9) * 1.6) * 0.8  # gentle glue
    data = (np.clip(x, -1, 1) * 32767).astype("<i2")
    with wave.open(os.path.join(OUT, name + ".wav"), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(data.tobytes())
    print(f"{name}.wav  {n / SR:.1f}s  {bars} bars at {bpm} bpm")


# ------------------------------------------------------------------ the six songs (original compositions)
def all_songs():
    # Studio Lounge (the studio + the Big Canvas map): relaxed lounge pop in F
    song("music_paper_stroll", 98,
         [(53, "maj7"), (50, "m7"), (55, "m7"), (48, "7")] * 2 + [(46, "maj7"), (45, "m7"), (50, "m7"), (55, "7")] * 2,
         {"a": [(0, 1.5, 6), (1.5, 0.5, 5), (2, 1, 4), (3, 1, 5)],
          "b": [(0, 0.5, 4), (0.5, 0.5, 5), (1, 0.5, 6), (1.5, 1.5, 7), (3.5, 0.5, 6)],
          "c": [(0, 3, 4), (3, 0.5, 2), (3.5, 0.5, 3)],
          "plan": ["a", "b", "a", "c", "a", "b", None, "c"]},
         swing=0.12, lead_kind="whistle", lead_oct=72, groove="lounge", pad_gain=0.06, lead_gain=0.15)

    # Meadow Fairway: sunny, bouncy pop in D with a whistly lead
    song("music_meadow_fairway", 124,
         [(50, "add9"), (55, "maj7"), (47, "m7"), (57, "sus")] * 2 + [(55, "maj7"), (57, "7"), (54, "m7"), (59, "m7")]
         + [(55, "maj7"), (52, "m7"), (57, "sus"), (57, "7")],
         {"a": [(0, 0.5, 4), (0.5, 0.5, 5), (1, 0.75, 6), (1.75, 0.75, 5), (2.5, 0.5, 4), (3, 1, 6)],
          "b": [(0, 1, 7), (1, 0.5, 6), (1.5, 0.5, 5), (2, 0.5, 4), (2.5, 0.5, 5), (3, 1, 4)],
          "c": [(0, 0.5, 6), (0.5, 0.5, 7), (1, 0.5, 8), (1.5, 1.5, 7), (3.5, 0.5, 6)],
          "d": [(0, 2.5, 4), (3, 0.5, 5), (3.5, 0.5, 6)],
          "plan": ["a", "b", "a", "d", "c", "b", "c", "d"]},
         swing=0.18, lead_kind="whistle", lead_oct=72, groove="pop")

    # Village Swing: jazzy swing pop in Bb with brass
    song("music_village_square", 132,
         [(46, "6"), (43, "m7"), (48, "m7"), (41, "7")] * 2 + [(51, "maj7"), (50, "m7"), (48, "m7"), (53, "7")] * 2,
         {"a": [(0, 0.5, 4), (0.5, 1, 6), (1.5, 0.5, 5), (2, 0.5, 4), (2.5, 0.5, 2), (3, 1, 4)],
          "b": [(0, 0.5, 7), (0.5, 0.5, 6), (1, 0.5, 5), (1.5, 0.5, 4), (2, 2, 5)],
          "c": [(0, 1, 6), (1, 1, 5), (2, 1, 6), (3, 0.5, 7), (3.5, 0.5, 8)],
          "plan": ["a", "b", "a", "c", "b", "a", "c", None]},
         swing=0.33, lead_kind="square", lead_oct=72, groove="swing", brass_stabs=True, lead_gain=0.12)

    # Seaside Sunset: tropical bossa in G with a steel-drum tune
    song("music_seaside_breeze", 108,
         [(55, "maj7"), (52, "m7"), (48, "maj7"), (50, "7")] * 2 + [(47, "m7"), (52, "7"), (45, "m7"), (50, "7")] * 2,
         {"a": [(0, 1, 6), (1, 0.5, 5), (1.5, 1, 4), (2.5, 0.5, 5), (3, 1, 6)],
          "b": [(0, 0.5, 7), (0.5, 0.5, 6), (1, 0.5, 5), (1.5, 0.5, 6), (2, 1.5, 4), (3.5, 0.5, 5)],
          "c": [(0, 0.5, 4), (0.75, 0.75, 6), (1.5, 0.5, 7), (2, 2, 6)],
          "plan": ["a", "b", "a", "c", "b", "a", "b", "c"]},
         swing=0.0, groove="bossa", steel_lead=True, lead_oct=72, lead_gain=0.2, pad_gain=0.06)

    # Snowy Sparkle: twinkly bell pop in E
    song("music_snowy_notebook", 104,
         [(52, "add9"), (59, "sus"), (61, "m7"), (57, "maj7")] * 2 + [(57, "maj7"), (56, "m7"), (54, "m7"), (59, "7")] * 2,
         {"a": [(0, 0.5, 6), (0.5, 0.5, 7), (1, 0.5, 8), (1.5, 0.5, 7), (2, 1, 6), (3, 1, 5)],
          "b": [(0, 1, 4), (1, 0.5, 5), (1.5, 0.5, 6), (2, 2, 7)],
          "c": [(0, 0.25, 8), (0.25, 0.25, 7), (0.5, 0.25, 6), (0.75, 0.25, 5), (1, 3, 4)],
          "plan": ["a", "b", "a", "c", "b", "a", "b", "c"]},
         swing=0.0, groove="sparkle", bells=True, lead_oct=72, lead_gain=0.2, pad_gain=0.07)

    # Castle Climb: heroic, driving finale in C minor that lifts to major
    song("music_castle_climb", 140,
         [(48, "m"), (44, "maj"), (46, "maj"), (43, "7")] * 2 + [(44, "maj7"), (46, "7"), (51, "maj"), (48, "maj")] * 2,
         {"a": [(0, 0.5, 4), (0.5, 0.5, 4), (1, 0.5, 5), (1.5, 1, 6), (2.5, 0.5, 5), (3, 1, 6)],
          "b": [(0, 1.5, 7), (1.5, 0.5, 6), (2, 0.5, 5), (2.5, 0.5, 6), (3, 1, 4)],
          "c": [(0, 0.5, 6), (0.5, 0.5, 7), (1, 1, 8), (2, 2, 7)],
          "plan": ["a", "b", "a", "b", "c", "b", "c", "a"]},
         swing=0.0, lead_kind="brass", lead_oct=72, groove="drive", brass_stabs=True, lead_gain=0.14)


all_songs()
