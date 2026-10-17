extends ColorRect
## The colour Play fades through on its way into the game (#27). The launcher
## fades it in over itself; once the game's scene is in, lift() has it fade
## itself away and free the layer it sits on.
##
## Its own script rather than a tween or a coroutine of the launcher's: the
## launcher is gone by then. And a frame at a time in real time, at most
## MAX_STEP of it per frame, rather than a Tween: loading the game's scene and
## the game's own _ready() stall the frames around the change, a Tween charges a
## stalled frame in full and showed the game's first frame half faded in, and a
## Tween runs on game time, which a game may have stopped with Engine.time_scale.

## The most of the fade one frame may take, however long that frame lasted.
const MAX_STEP := 1.0 / 30.0

var _seconds := 0.0
var _last_usec := 0


func _ready() -> void:
	set_process(false)


## Fades the veil away over [param seconds], then frees its parent layer.
func lift(seconds: float) -> void:
	_seconds = maxf(seconds, 0.001)
	_last_usec = Time.get_ticks_usec()
	set_process(true)


func _process(_delta: float) -> void:
	var now := Time.get_ticks_usec()
	color.a -= minf((now - _last_usec) / 1000000.0, MAX_STEP) / _seconds
	_last_usec = now
	if color.a <= 0.0:
		set_process(false)
		get_parent().queue_free()
