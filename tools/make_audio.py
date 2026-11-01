"""Synthesizes Mochi Sketchbook's music and sound effects (all original, made from sine/noise math).

Writes 16-bit mono WAVs to the folder given after "--" (default: godot/assets/audio).
Run with any Python that has numpy, e.g. Blender's:
    blender --background --factory-startup --python tools/make_audio.py -- godot/assets/audio
"""
import os
import sys
import wave

import numpy as np

OUT = sys.argv[sys.argv.index("--") + 1] if "--" in sys.argv else os.path.join(os.path.dirname(__file__), "..", "godot", "assets", "audio")
os.makedirs(OUT, exist_ok=True)
SR = 44100
rng = np.random.default_rng(3)


def t_(dur):
    return np.arange(int(dur * SR)) / SR


def note_hz(n):
    """MIDI note number -> Hz."""
    return 440.0 * 2 ** ((n - 69) / 12)


def env(n, a=0.005, d=0.3, curve=1.0):
    """Attack then exponential-ish decay over n samples."""
    t = np.arange(n) / SR
    att = np.clip(t / max(a, 1e-4), 0, 1)
    return att * np.exp(-t / max(d, 1e-4) * curve)


def lowpass(x, cutoff):
    """One-pole low-pass (cheap, warm)."""
    a = np.exp(-2 * np.pi * cutoff / SR)
    y = np.empty_like(x)
    acc = 0.0
    for i, v in enumerate(x):
        acc = (1 - a) * v + a * acc
        y[i] = acc
    return y


def glide(f0, f1, n, shape=1.0):
    """Phase for a pitch glide from f0 to f1 Hz over n samples."""
    k = np.linspace(0, 1, n) ** shape
    f = f0 + (f1 - f0) * k
    return 2 * np.pi * np.cumsum(f) / SR


def save(name, x, peak=0.8, fade=True):
    x = x / max(1e-9, np.max(np.abs(x))) * peak
    if fade:  # 15 ms fade-out so effects never end with a click
        k = min(len(x), int(0.015 * SR))
        x[-k:] *= np.linspace(1, 0, k)
    data = (np.clip(x, -1, 1) * 32767).astype("<i2")
    with wave.open(os.path.join(OUT, name + ".wav"), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(data.tobytes())
    print(f"{name}.wav  {len(x) / SR:.2f}s")


def bell(freq, dur, bright=0.35, decay=0.5):
    t = t_(dur)
    x = np.sin(2 * np.pi * freq * t) + bright * np.sin(2 * np.pi * freq * 2.0 * t) * np.exp(-t * 6) \
        + 0.12 * np.sin(2 * np.pi * freq * 3.01 * t) * np.exp(-t * 10)
    return x * env(len(t), 0.003, decay)


def blip(f0, f1, dur, vib=6.0, depth=0.03, tone=0.25):
    """Cute 'voice' blip: a sine glide with vibrato and a hint of overtone."""
    n = int(dur * SR)
    t = np.arange(n) / SR
    ph = glide(f0, f1, n) + depth * np.sin(2 * np.pi * vib * t) * 2 * np.pi
    x = np.sin(ph) + tone * np.sin(2 * ph) + 0.08 * np.sin(3 * ph)
    e = np.clip(t / 0.012, 0, 1) * np.clip((dur - t) / 0.04, 0, 1)
    return x * e


def mix(*parts):
    """parts: (signal, offset_seconds, gain)"""
    end = max(int(o * SR) + len(s) for s, o, g in parts)
    out = np.zeros(end)
    for s, o, g in parts:
        i = int(o * SR)
        out[i:i + len(s)] += s * g
    return out


# ================================================================== sound effects
def sfx():
    # paper footstep: a soft, short, filtered pat
    n = int(0.09 * SR)
    pat = lowpass(rng.standard_normal(n), 1800) * env(n, 0.002, 0.025)
    pat += 0.6 * np.sin(2 * np.pi * 180 * t_(0.09)) * env(n, 0.001, 0.02)
    save("step", pat, 0.5)

    # hop: one soft, round 'boing' per little walking hop (quiet and mellow so it never nags)
    n = int(0.22 * SR)
    t = t_(0.22)
    ph = glide(240, 400, n, 0.45) + 0.35 * np.sin(2 * np.pi * 15 * t) * np.exp(-t * 14)
    boing = (np.sin(ph) + 0.15 * np.sin(2 * ph)) * env(n, 0.006, 0.07)
    save("hop", lowpass(boing, 2200), 0.5)

    # eating a paint drop: an inhaling slurp, a big gulp, then happy little noms
    n = int(0.6 * SR)
    t = t_(0.6)
    air = rng.standard_normal(n)
    sweep = np.concatenate([lowpass(air[i:i + 2205], 500 + 3500 * (i / n)) for i in range(0, n, 2205)])[:n]
    slurp = sweep * np.clip(t / 0.15, 0, 1) * np.clip((0.6 - t) / 0.08, 0, 1)
    slurp += 0.25 * np.sin(glide(180, 420, n, 1.5)) * np.clip(t / 0.3, 0, 1) * np.clip((0.6 - t) / 0.1, 0, 1)
    save("slurp", slurp, 0.45)
    n = int(0.38 * SR)
    gulp = np.sin(glide(320, 85, n, 0.5)) * env(n, 0.004, 0.12)
    gulp += 0.5 * np.sin(glide(180, 60, n, 0.3)) * env(n, 0.01, 0.2)
    gulp += 0.3 * lowpass(rng.standard_normal(n), 1200) * env(n, 0.001, 0.02)  # the 'chomp'
    save("gulp", gulp, 0.7)
    noms = []
    for k, f in enumerate((420, 380, 440)):
        m = int(0.11 * SR)
        nom = np.sin(glide(f, f * 0.7, m)) * env(m, 0.004, 0.035) + 0.2 * lowpass(rng.standard_normal(m), 2500) * env(m, 0.001, 0.01)
        noms.append((nom, k * 0.21, 1.0))
    save("munch", mix(*noms), 0.45)

    # jump: springy rising boing
    n = int(0.32 * SR)
    ph = glide(260, 720, n, 0.6) + 0.15 * np.sin(2 * np.pi * 22 * t_(0.32))
    save("jump", (np.sin(ph) + 0.25 * np.sin(2 * ph)) * env(n, 0.004, 0.16), 0.6)

    # land: squishy plop
    n = int(0.25 * SR)
    plop = np.sin(glide(330, 110, n, 0.5)) * env(n, 0.002, 0.08)
    plop += 0.25 * lowpass(rng.standard_normal(n), 900) * env(n, 0.001, 0.03)
    save("land", plop, 0.6)

    # squish: rubbery squeak that wobbles
    n = int(0.42 * SR)
    t = t_(0.42)
    f = 520 + 160 * np.sin(2 * np.pi * 9 * t) * np.exp(-t * 4) - 120 * t
    ph = 2 * np.pi * np.cumsum(f) / SR
    sq = (np.sin(ph) + 0.4 * np.sin(2 * ph + 0.3)) * env(n, 0.01, 0.2)
    save("squish", lowpass(sq, 4000), 0.6)

    # collect a paint drop: sparkly rising arpeggio + a wet splash
    notes = [76, 79, 83, 88]
    chime = mix(*[(bell(note_hz(m), 0.9, 0.4, 0.35), i * 0.07, 1.0) for i, m in enumerate(notes)])
    n = int(0.5 * SR)
    splash = lowpass(rng.standard_normal(n), 2600) * env(n, 0.02, 0.12)
    save("collect", mix((chime, 0.0, 1.0), (splash, 0.02, 0.35)), 0.75)

    # win: a little fanfare
    seq = [(72, 0.0), (76, 0.12), (79, 0.24), (84, 0.36), (79, 0.6), (84, 0.72)]
    fan = mix(*[(bell(note_hz(m), 1.4 if i == len(seq) - 1 else 0.6, 0.45, 0.5), o, 1.0) for i, (m, o) in enumerate(seq)])
    chord = mix(*[(bell(note_hz(m), 1.8, 0.2, 0.9), 0.72, 0.4) for m in (60, 64, 67)])
    save("win", mix((fan, 0, 1.0), (chord, 0, 1.0)), 0.8)

    # UI: pencil tap
    n = int(0.06 * SR)
    tap = lowpass(rng.standard_normal(n), 5000) * env(n, 0.0005, 0.008)
    tap += 0.5 * np.sin(2 * np.pi * 1400 * t_(0.06)) * env(n, 0.0005, 0.01)
    save("click", tap, 0.45)

    # emote voices
    save("emote_happy", mix((blip(620, 820, 0.11), 0, 1), (blip(760, 1050, 0.13), 0.13, 1),
                            (bell(note_hz(88), 0.5, 0.3, 0.2), 0.25, 0.35)), 0.6)
    save("emote_love", mix((blip(900, 560, 0.28, 5, 0.04), 0, 1), (bell(note_hz(84), 0.8, 0.3, 0.4), 0.22, 0.5),
                           (bell(note_hz(91), 0.8, 0.3, 0.4), 0.42, 0.35)), 0.6)
    n = int(0.6 * SR)
    t = t_(0.6)
    ph = glide(150, 120, n) + 0.6 * np.sin(2 * np.pi * 11 * t)
    grumble = np.sign(np.sin(ph)) * 0.5 + np.sin(ph) * 0.5
    grumble = lowpass(grumble, 900) * (0.7 + 0.3 * np.sin(2 * np.pi * 13 * t)) * env(n, 0.03, 0.35)
    save("emote_angry", grumble, 0.55)
    save("emote_sad", mix((blip(620, 380, 0.55, 7, 0.05), 0, 1), (blip(420, 300, 0.4, 7, 0.05), 0.5, 0.7)), 0.55)
    save("emote_surprised", mix((blip(380, 1100, 0.18, 0, 0, 0.35), 0, 1), (bell(note_hz(93), 0.5, 0.4, 0.2), 0.12, 0.4)), 0.6)
    n = int(1.1 * SR)
    t = t_(1.1)
    snore = blip(240, 200, 1.1, 3, 0.02, 0.1) * (0.5 + 0.5 * np.sin(2 * np.pi * 0.9 * t - 1.2))
    breath = lowpass(rng.standard_normal(n), 600) * 0.3 * np.clip(np.sin(np.pi * t / 1.1), 0, 1)
    save("emote_sleepy", lowpass(snore, 1500) + breath, 0.45)


# ================================================================== music: "Paper Stroll" (seamless loop)
def music():
    bpm = 84
    beat = 60 / bpm
    bars = 8
    total = bars * 4 * beat
    n = int(total * SR)
    tail = int(3.0 * SR)  # rendered past the end, then wrapped onto the start for a seamless loop
    out = np.zeros(n + tail)

    def put(sig, start_s, gain):
        i = int(start_s * SR)
        out[i:i + len(sig)] += sig[:max(0, len(out) - i)] * gain

    # chords: C maj7 | A m7 | F maj7 | G6, twice
    chords = [[48, 55, 59, 64], [45, 52, 55, 60], [41, 48, 52, 57], [43, 50, 55, 59]] * 2
    for b, ch in enumerate(chords):
        start = b * 4 * beat
        dur = 4 * beat + 0.6
        tt = t_(dur)
        pad = sum(np.sin(2 * np.pi * note_hz(m + 12) * tt + k) * (0.6 if k else 1.0) for k, m in enumerate(ch[1:]))
        pad *= np.clip(tt / 0.5, 0, 1) * np.clip((dur - tt) / 0.6, 0, 1)
        put(lowpass(pad, 1200), start, 0.07)
        for beat_i, gain in ((0, 1.0), (2, 0.7)):  # soft bass on 1 and 3
            put(np.sin(2 * np.pi * note_hz(ch[0]) * t_(1.2)) * env(int(1.2 * SR), 0.01, 0.45), start + beat_i * beat, 0.32 * gain)
    # music-box melody (C major pentatonic), 8th notes; None = rest
    phrase_a = [76, None, 79, 81, 79, None, 76, 74, 72, None, 74, 76, 74, None, None, None,
                69, None, 72, 74, 76, None, 74, 72, 74, None, 72, 69, 67, None, None, None]
    phrase_b = [76, 79, 81, None, 84, 81, 79, None, 76, None, 79, 76, 74, None, 72, None,
                72, None, 74, 76, 79, None, 76, 74, 72, None, None, 67, 72, None, None, None]
    for i, m in enumerate(phrase_a + phrase_b):
        if m is not None:
            put(bell(note_hz(m), 1.2, 0.3, 0.42), i * beat / 2, 0.22)
    # an echo of the melody an octave up, very quiet, for sparkle
    for i, m in enumerate(phrase_a + phrase_b):
        if m is not None and i % 4 == 0:
            put(bell(note_hz(m + 12), 0.8, 0.2, 0.25), i * beat / 2 + beat * 0.75, 0.05)
    # pencil taps on the off-beats, a soft paper brush on 2 and 4
    for k in range(bars * 4):
        tap_n = int(0.05 * SR)
        tap = lowpass(rng.standard_normal(tap_n), 4500) * env(tap_n, 0.0005, 0.01)
        put(tap, k * beat + beat / 2, 0.06)
        if k % 2 == 1:
            bn = int(0.18 * SR)
            brush = lowpass(rng.standard_normal(bn), 2200) * env(bn, 0.02, 0.06)
            put(brush, k * beat, 0.07)
    out[:tail] += out[n:n + tail]
    save("music_paper_stroll", out[:n], 0.7, fade=False)


sfx()
music()
