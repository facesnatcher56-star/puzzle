class_name BoardFx
extends Node2D

# World-space celebration effects drawn above the pieces: expanding rings and sparkle bursts.

class Ring extends Node2D:
	var radius := 0.0
	var alpha := 1.0
	var width := 6.0
	var color := Color.WHITE

	func _draw() -> void:
		draw_arc(Vector2.ZERO, maxf(radius, 0.1), 0.0, TAU, 72, Color(color.r, color.g, color.b, color.a * alpha), width, true)

func ring(world_position: Vector2, max_radius: float, color: Color, duration: float, width: float = 6.0) -> void:
	var ring_node := Ring.new()
	ring_node.position = world_position
	ring_node.color = color
	ring_node.width = width
	add_child(ring_node)
	var tween := create_tween().set_parallel(true)
	tween.tween_method(func(value: float): ring_node.radius = value; ring_node.queue_redraw(), 0.0, max_radius, duration).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tween.tween_method(func(value: float): ring_node.alpha = value; ring_node.queue_redraw(), 1.0, 0.0, duration)
	tween.chain().tween_callback(ring_node.queue_free)

func sparkles(world_position: Vector2, count: int, color: Color, speed: float, lifetime: float = 0.9, size: float = 7.0) -> void:
	var particles := CPUParticles2D.new()
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
	particles.scale_amount_min = size * 0.5
	particles.scale_amount_max = size
	var fade := Gradient.new()
	fade.set_color(0, color)
	fade.set_color(1, Color(color.r, color.g, color.b, 0.0))
	particles.color_ramp = fade
	add_child(particles)
	particles.emitting = true
	get_tree().create_timer(lifetime + 0.3).timeout.connect(particles.queue_free)
