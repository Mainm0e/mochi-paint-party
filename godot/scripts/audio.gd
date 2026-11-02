class_name Audio
extends Node
## Music + sound effects. Sets up Music and SFX buses (the music bus has a low-pass that muffles it
## while paused), loops the background track, and plays one-shot effects from a small voice pool.
## The sounds are synthesized by tools/make_audio.py.

const DIR := "res://assets/audio/"
const SOUNDS := ["step", "hop", "jump", "land", "squish", "collect", "win", "click", "slurp", "gulp", "munch",
	"step_grass", "step_stone", "step_wood", "step_sand", "step_water", "splash", "bubble", "scribble", "tide",
	"step_snow", "step_ice", "melt", "boing", "night",
	"emote_happy", "emote_love", "emote_angry", "emote_sad", "emote_surprised", "emote_sleepy"]
const MUSIC_DB := -9.0    # music sits under the effects
const TRACKS := ["music_paper_stroll", "music_meadow_fairway", "music_village_square", "music_seaside_breeze",
	"music_snowy_notebook", "music_castle_climb"]  # made by tools/make_music.py
const VOICES := 10

var streams := {}
var tracks := {}                 # music loops by name
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
	for name in TRACKS:
		var track: AudioStreamWAV = load(DIR + name + ".wav")
		track.loop_mode = AudioStreamWAV.LOOP_FORWARD
		track.loop_begin = 0
		track.loop_end = int(track.get_length() * track.mix_rate)
		tracks[name] = track
	music = AudioStreamPlayer.new()
	music.stream = tracks[TRACKS[0]]
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


## Switch to another page's theme: the old one fades out, the new one fades in from its start.
func play_music(track_name: String) -> void:
	if not tracks.has(track_name) or (music.stream == tracks[track_name] and music.playing):
		return
	var tw := create_tween()
	tw.tween_property(music, "volume_db", -40.0, 0.6)
	tw.tween_callback(func():
		music.stream = tracks[track_name]
		music.play())
	tw.tween_property(music, "volume_db", MUSIC_DB, 0.8)


## Muffle the music (pause menu) or bring it back.
func muffle(on: bool) -> void:
	AudioServer.set_bus_effect_enabled(_music_bus, 0, on)


func set_volume(bus_name: String, linear: float) -> void:
	var i := _music_bus if bus_name == "Music" else _sfx_bus
	AudioServer.set_bus_volume_db(i, linear_to_db(maxf(linear, 0.0001)))
	AudioServer.set_bus_mute(i, linear <= 0.001)
