class_name BoardFx
extends Node2D

# World-space celebration effects drawn above the pieces: expanding rings and sparkle bursts.
# Sprites in assets/fx/ are rendered in Blender (tools/render_fx.py) and tinted per effect.

const GLOW_TEXTURE := preload("res://assets/fx/glow.png")
const SPARKLE_TEXTURE := preload("res://assets/fx/sparkle.png")
const RING_TEXTURE := preload("res://assets/fx/ring.png")
const RAYS_TEXTURE := preload("res://assets/fx/rays.png")
const CONFETTI_TEXTURES := [
	preload("res://assets/fx/confetti0.png"),
	preload("res://assets/fx/confetti1.png"),
	preload("res://assets/fx/confetti2.png"),
]
const CONFETTI_COLORS := [Color("ffd166"), Color("ef476f"), Color("06d6a0"), Color("4cc9f0"), Color("f8f4e3"), Color("ff9f1c")]

static var _additive: CanvasItemMaterial

static func additive_material() -> CanvasItemMaterial:
	if _additive == null:
		_additive = CanvasItemMaterial.new()
		_additive.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	return _additive

class Ring extends Node2D:
	var radius := 0.0
	var alpha := 1.0
	var width := 6.0
	var color := Color.WHITE

	func _draw() -> void:
		var half := maxf(radius, 0.1) + width * 2.0
		draw_texture_rect(RING_TEXTURE, Rect2(-Vector2(half, half), Vector2(half, half) * 2.0), false, Color(color.r, color.g, color.b, color.a * alpha))

func ring(world_position: Vector2, max_radius: float, color: Color, duration: float, width: float = 6.0) -> void:
	var ring_node := Ring.new()
	ring_node.position = world_position
	ring_node.color = color
	ring_node.width = width
	ring_node.material = additive_material()
	add_child(ring_node)
	var tween := create_tween().set_parallel(true)
	tween.tween_method(func(value: float): ring_node.radius = value; ring_node.queue_redraw(), 0.0, max_radius, duration).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tween.tween_method(func(value: float): ring_node.alpha = value; ring_node.queue_redraw(), 1.0, 0.0, duration)
	tween.chain().tween_callback(ring_node.queue_free)
	flash(world_position, max_radius * 0.5, color, duration * 0.6)

# A short soft glow that swells and fades, under the sparkles and rings.
func flash(world_position: Vector2, flash_radius: float, color: Color, duration: float) -> void:
	var glow := Sprite2D.new()
	glow.texture = GLOW_TEXTURE
	glow.position = world_position
	glow.modulate = Color(color.r, color.g, color.b, 0.0)
	glow.material = additive_material()
	var base_scale := flash_radius * 2.0 / GLOW_TEXTURE.get_width()
	glow.scale = Vector2.ONE * base_scale * 0.4
	add_child(glow)
	var tween := create_tween().set_parallel(true)
	tween.tween_property(glow, "scale", Vector2.ONE * base_scale, duration).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tween.tween_property(glow, "modulate:a", 0.9, duration * 0.25)
	tween.chain().tween_property(glow, "modulate:a", 0.0, duration * 0.75)
	tween.chain().tween_callback(glow.queue_free)

func sparkles(world_position: Vector2, count: int, color: Color, speed: float, lifetime: float = 0.9, size: float = 7.0) -> void:
	var particles := CPUParticles2D.new()
	particles.texture = SPARKLE_TEXTURE
	particles.material = additive_material()
	particles.angular_velocity_min = -180.0
	particles.angular_velocity_max = 180.0
	particles.position = world_position
	particles.amount = count
	particles.one_shot = true
	particles.explosiveness = 1.0
	particles.lifetime = lifetime
	particles.direction = Vector2.UP
	particles.spread = 180.0
	particles.initial_velocity_min = speed * 0.35
	particles.initial_velocity_max = speed
	particles.gravity = Vector2(0, speed * 0.6)
	particles.damping_min = speed * 0.4
	particles.damping_max = speed * 0.8
	particles.scale_amount_min = size * 0.5 / 64.0
	particles.scale_amount_max = size / 64.0 * 2.0
	var fade := Gradient.new()
	fade.set_color(0, color)
	fade.set_color(1, Color(color.r, color.g, color.b, 0.0))
	particles.color_ramp = fade
	add_child(particles)
	particles.emitting = true
	if count >= 8:
		flash(world_position, size * 6.0, color, lifetime * 0.5)
	get_tree().create_timer(lifetime + 0.3).timeout.connect(particles.queue_free)

# A slowly turning fan of light beams that swells and fades.
func rays(world_position: Vector2, radius: float, color: Color, duration: float, spin: float = 0.6) -> void:
	var sprite := Sprite2D.new()
	sprite.texture = RAYS_TEXTURE
	sprite.position = world_position
	sprite.modulate = Color(color.r, color.g, color.b, 0.0)
	sprite.material = additive_material()
	var full := radius * 2.0 / RAYS_TEXTURE.get_width()
	sprite.scale = Vector2.ONE * full * 0.5
	add_child(sprite)
	var tween := create_tween().set_parallel(true)
	tween.tween_property(sprite, "scale", Vector2.ONE * full, duration).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_property(sprite, "rotation", spin * duration, duration)
	tween.tween_property(sprite, "modulate:a", color.a, duration * 0.2)
	tween.chain().tween_property(sprite, "modulate:a", 0.0, duration * 0.8)
	tween.chain().tween_callback(sprite.queue_free)

# Tumbling coloured confetti thrown from a point in `direction` (a cone of `spread` degrees).
func confetti(world_position: Vector2, count: int, speed: float, lifetime: float = 1.8, direction: Vector2 = Vector2.UP, spread: float = 70.0, size: float = 16.0) -> void:
	for texture in CONFETTI_TEXTURES:
		var particles := _confetti_emitter(texture, maxi(1, count / CONFETTI_TEXTURES.size()), lifetime, size)
		particles.position = world_position
		particles.explosiveness = 0.95
		particles.direction = direction
		particles.spread = spread
		particles.initial_velocity_min = speed * 0.4
		particles.initial_velocity_max = speed
		particles.gravity = Vector2(0, speed * 0.8)
		particles.damping_min = speed * 0.25
		particles.damping_max = speed * 0.5
		_run_oneshot(particles, lifetime)

# A shower falling through `area` (world rect) over `duration` seconds.
func confetti_rain(area: Rect2, count: int, duration: float, fall_speed: float = 260.0, size: float = 16.0) -> void:
	var lifetime := minf(duration, 3.5)
	for texture in CONFETTI_TEXTURES:
		var particles := _confetti_emitter(texture, maxi(1, count / CONFETTI_TEXTURES.size()), lifetime, size)
		particles.position = area.get_center()
		particles.one_shot = true
		particles.explosiveness = 0.0
		particles.emission_shape = CPUParticles2D.EMISSION_SHAPE_RECTANGLE
		particles.emission_rect_extents = area.size * 0.5
		particles.direction = Vector2.DOWN
		particles.spread = 12.0
		particles.initial_velocity_min = fall_speed * 0.6
		particles.initial_velocity_max = fall_speed
		particles.gravity = Vector2(0, fall_speed * 0.4)
		particles.lifetime = lifetime
		_run_oneshot(particles, lifetime + duration)

func _confetti_emitter(texture: Texture2D, amount: int, lifetime: float, size: float) -> CPUParticles2D:
	var particles := CPUParticles2D.new()
	particles.texture = texture
	particles.amount = amount
	particles.lifetime = lifetime
	particles.one_shot = true
	particles.angular_velocity_min = -540.0
	particles.angular_velocity_max = 540.0
	particles.angle_max = 360.0
	particles.scale_amount_min = size / 128.0
	particles.scale_amount_max = size / 128.0 * 1.8
	var tint := Gradient.new()
	tint.interpolation_mode = Gradient.GRADIENT_INTERPOLATE_CONSTANT
	tint.offsets = PackedFloat32Array(range(CONFETTI_COLORS.size()).map(func(i): return float(i) / CONFETTI_COLORS.size()))
	tint.colors = PackedColorArray(CONFETTI_COLORS)
	particles.color_initial_ramp = tint
	var fade := Gradient.new()
	fade.offsets = PackedFloat32Array([0.0, 0.7, 1.0])
	fade.colors = PackedColorArray([Color.WHITE, Color.WHITE, Color(1, 1, 1, 0)])
	particles.color_ramp = fade
	return particles

func _run_oneshot(particles: CPUParticles2D, lifetime: float) -> void:
	add_child(particles)
	particles.emitting = true
	get_tree().create_timer(lifetime + 0.4).timeout.connect(particles.queue_free)
