class_name AmbientMotes
extends CanvasLayer

# Slow glowing dust drifting across the whole screen, above the table and below the UI.

var _particles := CPUParticles2D.new()

func _ready() -> void:
	layer = 1
	_particles.texture = UiStyle.GLOW
	_particles.material = BoardFx.additive_material()
	_particles.amount = 34
	_particles.lifetime = 14.0
	_particles.preprocess = 14.0
	_particles.emission_shape = CPUParticles2D.EMISSION_SHAPE_RECTANGLE
	_particles.direction = Vector2(0.3, -1.0)
	_particles.spread = 40.0
	_particles.initial_velocity_min = 6.0
	_particles.initial_velocity_max = 20.0
	_particles.scale_amount_min = 0.08
	_particles.scale_amount_max = 0.3
	var fade := Gradient.new()
	fade.offsets = PackedFloat32Array([0.0, 0.25, 0.75, 1.0])
	fade.colors = PackedColorArray([Color(1, 0.9, 0.6, 0), Color(1, 0.9, 0.6, 0.22), Color(0.7, 1, 0.95, 0.18), Color(0.7, 1, 0.95, 0)])
	_particles.color_ramp = fade
	add_child(_particles)
	get_viewport().size_changed.connect(_fit)
	_fit()

func _fit() -> void:
	var size := get_viewport().get_visible_rect().size
	_particles.position = size * 0.5
	_particles.emission_rect_extents = size * 0.5
