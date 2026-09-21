#!/usr/bin/env python3
"""Procedurally generates all placeholder audio for the project.

Run from anywhere:  python3 tools/generate_audio.py
Writes 16-bit mono 22050 Hz WAV files into assets/audio/.
Keeps the repo self-contained: no external audio downloads required.
"""
import math
import os
import random
import struct
import wave

SR = 22050
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "assets", "audio")
random.seed(1337)


def write_wav(name, samples):
    os.makedirs(OUT, exist_ok=True)
    path = os.path.join(OUT, name)
    peak = max(1e-9, max(abs(s) for s in samples))
    norm = 0.95 / peak if peak > 0.95 else 1.0
    with wave.open(path, "w") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(b"".join(struct.pack("<h", int(max(-1, min(1, s * norm)) * 32767)) for s in samples))
    print("wrote", name, f"({len(samples)/SR:.2f}s)")


def env_adsr(n, a, d, s, r, sustain_level=0.6):
    """Simple ADSR envelope. a/d/s/r are fractions of total length."""
    na, nd, ns, nr = int(n*a), int(n*d), int(n*s), int(n*r)
    out = []
    for i in range(n):
        if i < na:
            out.append(i / max(1, na))
        elif i < na + nd:
            out.append(1.0 - (1.0 - sustain_level) * (i - na) / max(1, nd))
        elif i < na + nd + ns:
            out.append(sustain_level)
        else:
            out.append(sustain_level * (1.0 - (i - na - nd - ns) / max(1, nr)))
    return out


def lpf(samples, alpha):
    """One-pole low-pass filter."""
    out = []
    y = 0.0
    for s in samples:
        y += alpha * (s - y)
        out.append(y)
    return out


def noise(n):
    return [random.uniform(-1, 1) for _ in range(n)]


def sine(freq, n, phase=0.0):
    return [math.sin(2 * math.pi * freq * i / SR + phase) for i in range(n)]


def mix(*tracks):
    n = max(len(t) for t in tracks)
    out = [0.0] * n
    for t in tracks:
        for i, s in enumerate(t):
            out[i] += s
    return out


def gain(samples, g):
    return [s * g for s in samples]


def apply_env(samples, env):
    return [s * e for s, e in zip(samples, env)]


# --- Ambient drone: low detuned sines + filtered noise, 30 s seamless loop ---
n = SR * 30
t = [i / SR for i in range(n)]
drone = []
for i in range(n):
    lfo = 0.85 + 0.15 * math.sin(2 * math.pi * 0.05 * t[i])
    s = (0.30 * math.sin(2 * math.pi * 55.0 * t[i])
         + 0.18 * math.sin(2 * math.pi * 55.6 * t[i])
         + 0.12 * math.sin(2 * math.pi * 82.4 * t[i])
         + 0.05 * math.sin(2 * math.pi * 164.8 * t[i] + 1.7))
    drone.append(s * lfo)
wn = lpf(noise(n), 0.02)
drone = mix(drone, gain(wn, 0.35))
# seamless loop: crossfade last/first 2 s
fade = SR * 2
for i in range(fade):
    k = i / fade
    drone[i] = drone[i] * k + drone[n - fade + i] * (1 - k)
drone = drone[: n - fade]
write_wav("ambient_drone.wav", drone)

# --- Footsteps x4: filtered noise thump ---
for k in range(4):
    n = int(SR * 0.14)
    e = env_adsr(n, 0.02, 0.15, 0.2, 0.63, 0.4)
    s = apply_env(lpf(noise(n), 0.28 + k * 0.04), e)
    body = apply_env(sine(70 + k * 12, n), env_adsr(n, 0.01, 0.3, 0.1, 0.59, 0.3))
    write_wav(f"footstep_{k+1}.wav", mix(gain(s, 0.8), gain(body, 0.5)))

# --- Enemy footstep: heavier ---
n = int(SR * 0.28)
s = apply_env(lpf(noise(n), 0.15), env_adsr(n, 0.02, 0.2, 0.2, 0.58, 0.4))
body = apply_env(sine(45, n), env_adsr(n, 0.01, 0.3, 0.1, 0.59, 0.3))
write_wav("enemy_step.wav", mix(gain(s, 0.8), gain(body, 0.9)))

# --- Door creak: jittery descending sine + noise ---
n = int(SR * 1.4)
s = []
f0 = 320.0
phase = 0.0
for i in range(n):
    f = f0 - 130.0 * (i / n) + 30.0 * math.sin(2 * math.pi * 7.0 * i / SR) + random.uniform(-12, 12)
    phase += 2 * math.pi * f / SR
    s.append(math.sin(phase) * 0.5)
s = apply_env(s, env_adsr(n, 0.1, 0.2, 0.4, 0.3, 0.5))
s = mix(s, gain(apply_env(noise(n), env_adsr(n, 0.15, 0.2, 0.4, 0.25, 0.3)), 0.15))
write_wav("door_creak.wav", s)

# --- Door locked: metallic thunk (inharmonic partials) ---
n = int(SR * 0.4)
s = [0.0] * n
for f in (180, 437, 889, 1410):
    partial = apply_env(sine(f, n), env_adsr(n, 0.005, 0.3, 0.05, 0.645, 0.2))
    s = mix(s, gain(partial, 0.4))
s = mix(s, gain(apply_env(noise(n), env_adsr(n, 0.002, 0.1, 0.02, 0.878, 0.1)), 0.3))
write_wav("door_locked.wav", s)

# --- Pickup / key: bright two-tone blip ---
n = int(SR * 0.35)
s1 = apply_env(sine(660, n), env_adsr(n, 0.01, 0.2, 0.1, 0.69, 0.3))
s2 = apply_env(sine(990, int(n * 0.6)), env_adsr(int(n * 0.6), 0.01, 0.3, 0.1, 0.59, 0.3))
s2 = [0.0] * int(n * 0.4) + s2
write_wav("pickup.wav", mix(gain(s1, 0.5), gain(s2, 0.5)))

# --- Note rustle: shaped noise ---
n = int(SR * 0.5)
s = apply_env(noise(n), env_adsr(n, 0.08, 0.25, 0.3, 0.37, 0.35))
write_wav("note_rustle.wav", lpf(s, 0.6))

# --- Jumpscare: screech + sub thump ---
n = int(SR * 1.6)
s = []
phase = 0.0
for i in range(n):
    f = 1400 - 950 * (i / n)
    phase += 2 * math.pi * f / SR
    s.append(math.sin(phase) * 0.6 + math.sin(phase * 0.5) * 0.35)
s = apply_env(s, env_adsr(n, 0.005, 0.1, 0.5, 0.395, 0.55))
sub = apply_env(sine(40, n), env_adsr(n, 0.01, 0.2, 0.4, 0.39, 0.5))
s = mix(s, gain(sub, 0.9), gain(noise(n), 0.25))
write_wav("jumpscare.wav", s)

# --- Heartbeat loop: lub-dub, 4 s ---
n = SR * 4
s = [0.0] * n
for start, amp in ((0, 0.9), (int(SR * 0.35), 0.6), (SR * 2, 0.9), (int(SR * 2.35), 0.6)):
    thump = apply_env(sine(52, int(SR * 0.22)), env_adsr(int(SR * 0.22), 0.03, 0.35, 0.1, 0.52, 0.2))
    for i, v in enumerate(thump):
        if start + i < n:
            s[start + i] += v * amp
write_wav("heartbeat.wav", s)

# --- Enemy growl: FM growl ---
n = int(SR * 2.2)
s = []
phase = 0.0
for i in range(n):
    mod = math.sin(2 * math.pi * 11.0 * i / SR) * 25.0 + math.sin(2 * math.pi * 3.1 * i / SR) * 15.0
    phase += 2 * math.pi * (68 + mod) / SR
    s.append(math.sin(phase) * 0.55 + math.sin(phase * 1.5) * 0.2)
s = apply_env(s, env_adsr(n, 0.15, 0.2, 0.4, 0.25, 0.6))
s = mix(s, gain(lpf(noise(n), 0.08), 0.3))
write_wav("enemy_growl.wav", s)

# --- Flashlight flicker buzz ---
n = int(SR * 0.18)
s = [0.4 * (1 if math.sin(2 * math.pi * 100 * i / SR) > 0 else -1) for i in range(n)]
s = mix(s, gain(noise(n), 0.15))
write_wav("flicker.wav", apply_env(s, env_adsr(n, 0.05, 0.2, 0.3, 0.45, 0.3)))

# --- Escape/win sting ---
n = int(SR * 1.6)
s = [0.0] * n
for f in (220, 277.2, 329.6):
    p = apply_env(sine(f, n), env_adsr(n, 0.05, 0.3, 0.3, 0.35, 0.5))
    s = mix(s, gain(p, 0.4))
write_wav("escape_sting.wav", s)

# --- UI / toast blip ---
n = int(SR * 0.12)
write_wav("blip.wav", apply_env(sine(440, n), env_adsr(n, 0.02, 0.3, 0.1, 0.58, 0.3)))

print("done")
