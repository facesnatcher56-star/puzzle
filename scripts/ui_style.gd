class_name UiStyle
extends RefCounted

# The game's shared look: bevelled gold-rimmed panels, buttons and slots. The textures are rendered in Blender
# (tools/render_fx.py) and stretched as 9-patches; this is the only place that knows their margins.

const PANEL := preload("res://assets/fx/ui_panel.png")
const BUTTON := preload("res://assets/fx/ui_button.png")
const BUTTON_HOVER := preload("res://assets/fx/ui_button_hover.png")
const BUTTON_PRESSED := preload("res://assets/fx/ui_button_pressed.png")
const SLOT := preload("res://assets/fx/ui_slot.png")
const SLOT_HOT := preload("res://assets/fx/ui_slot_hot.png")
const BAR_FILL := preload("res://assets/fx/ui_bar_fill.png")
const GEM := preload("res://assets/fx/gem.png")
const GLOW := preload("res://assets/fx/glow.png")

static func _box(texture: Texture2D, margin: int, pad_x: float, pad_y: float, tint: Color = Color.WHITE) -> StyleBoxTexture:
	var box := StyleBoxTexture.new()
	box.texture = texture
	box.set_texture_margin_all(margin)
	box.content_margin_left = pad_x
	box.content_margin_right = pad_x
	box.content_margin_top = pad_y
	box.content_margin_bottom = pad_y
	box.modulate_color = tint
	return box

static func panel(pad: float = 8.0) -> StyleBoxTexture:
	return _box(PANEL, 44, pad, pad)

static func button(hover: bool = false, pressed: bool = false) -> StyleBoxTexture:
	return _box(BUTTON_PRESSED if pressed else (BUTTON_HOVER if hover else BUTTON), 16, 16, 9)

static func slot(hot: bool, tint: Color = Color.WHITE) -> StyleBoxTexture:
	return _box(SLOT_HOT if hot else SLOT, 20, 0, 0, tint)

static func bar_fill(tint: Color) -> StyleBoxTexture:
	return _box(BAR_FILL, 6, 0, 0, tint)

# Buttons and panels for any Control subtree that sets `theme` to this.
static func theme() -> Theme:
	var result := Theme.new()
	result.set_stylebox("normal", "Button", button())
	result.set_stylebox("hover", "Button", button(true))
	result.set_stylebox("pressed", "Button", button(false, true))
	result.set_stylebox("focus", "Button", StyleBoxEmpty.new())
	result.set_stylebox("panel", "PanelContainer", panel())
	result.set_color("font_color", "Button", Color("eef0e6"))
	result.set_color("font_hover_color", "Button", Color("fff2cf"))
	result.set_color("font_pressed_color", "Button", Color("ffe9a8"))
	return result

# A gem (one Power Charge) centred on `at`, `height` pixels tall.
static func draw_gem(canvas: CanvasItem, at: Vector2, height: float, tint: Color = Color.WHITE) -> void:
	canvas.draw_texture_rect(GEM, Rect2(at - Vector2(height, height) * 0.5, Vector2(height, height)), false, tint)
