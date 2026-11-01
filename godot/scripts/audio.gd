class_name Audio
extends Node
## Music + sound effects. Sets up Music and SFX buses (the music bus has a low-pass that muffles it
## while paused), loops the background track, and plays one-shot effects from a small voice pool.
## The sounds are synthesized by tools/make_audio.py.

const DIR := "res://assets/audio/"
const SOUNDS := ["step", "hop", "jump", "land", "squish", "collect", "win", "click",
	"emote_happy", "emote_love", "emote_angry", "emote_sad", "emote_surprised", "emote_sleepy"]
const MUSIC_DB := -9.0    # music sits under the effects
const VOICES := 10

var streams := {}
var music: AudioStreamPlayer
var _pool: Array[AudioStreamPlayer] = []
var _next := 0
var _music_bus := -1
var _sfx_bus := -1


func _ready() -> void:
	_music_bus = _bus("Music")
	_sfx_bus = _bus("SFX")
	var lp := AudioEffectLowPassFilter.new()
	lp.cutoff_hz = 900.0
	AudioServer.add_bus_effect(_music_bus, lp)
	AudioServer.set_bus_effect_enabled(_music_bus, 0, false)
	for s in SOUNDS:
		streams[s] = load(DIR + s + ".wav")
	var track: AudioStreamWAV = load(DIR + "music_paper_stroll.wav")
	track.loop_mode = AudioStreamWAV.LOOP_FORWARD
	track.loop_begin = 0
	track.loop_end = int(track.get_length() * track.mix_rate)
	music = AudioStreamPlayer.new()
	music.stream = track
	music.bus = "Music"
	music.volume_db = MUSIC_DB
	add_child(music)
	for i in VOICES:
		var p := AudioStreamPlayer.new()
		p.bus = "SFX"
		add_child(p)
		_pool.append(p)


func _bus(bus_name: String) -> int:
	var i := AudioServer.get_bus_index(bus_name)
	if i == -1:
		AudioServer.add_bus()
		i = AudioServer.bus_count - 1
		AudioServer.set_bus_name(i, bus_name)
		AudioServer.set_bus_send(i, "Master")
	return i


## Play a one-shot effect; `jitter` randomises pitch a little so repeats don't sound robotic.
func play(sound: String, volume_db := 0.0, jitter := 0.06, pitch := 1.0) -> void:
	if not streams.has(sound):
		return
	var p := _pool[_next]
	_next = (_next + 1) % _pool.size()
	p.stream = streams[sound]
	p.volume_db = volume_db
	p.pitch_scale = pitch * (1.0 + randf_range(-jitter, jitter))
	p.play()


func start_music() -> void:
	if not music.playing:
		music.play()


## Muffle the music (pause menu) or bring it back.
func muffle(on: bool) -> void:
	AudioServer.set_bus_effect_enabled(_music_bus, 0, on)


func set_volume(bus_name: String, linear: float) -> void:
	var i := _music_bus if bus_name == "Music" else _sfx_bus
	AudioServer.set_bus_volume_db(i, linear_to_db(maxf(linear, 0.0001)))
	AudioServer.set_bus_mute(i, linear <= 0.001)
