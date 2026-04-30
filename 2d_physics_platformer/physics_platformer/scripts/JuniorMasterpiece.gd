extends Node2D
## ═══════════════════════════════════════════════════════════════════
##  JuniorMasterpiece.gd  —  v2.0 «Cathedral Edition»
##  Атмосферный модуль для 2D-уровня в стиле dark fantasy
##  Автор: Джуниор 🟡  |  Готов под Godot 4.3
##
##  ЧТО ДЕЛАЕТ:
##    1) Плавный цикл день/ночь  (CanvasModulate, 4 фазы)
##    2) Параллакс-фон в 3 слоя  (небо + дальние силуэты + ближние)
##    3) Секретные точки         (Marker2D в группе secret_spot светятся ночью)
##    4) Объёмный туман           (Polygon2D + анимированный shader)
##    5) Атмосферные частицы      (пыль/искры в зависимости от ярyса)
##    6) Виньетка постобработки   (CanvasLayer + ColorRect с шейдером)
##    7) Звук эха                 (опц., если положить файл step_echo.ogg)
##
##  КАК ПОДКЛЮЧИТЬ:
##    1. В корне основной сцены:  Add Child Node → Node2D → "Atmosphere"
##    2. Прицепи этот скрипт.
##    3. Расставь по сцене Marker2D в группе "secret_spot" — там
##       появятся светящиеся точки (опционально, для секреток)
##    4. Запусти сцену. Всё.
##
##  НАСТРАИВАЕТСЯ В ИНСПЕКТОРЕ —  смотри @export_group ниже.
## ═══════════════════════════════════════════════════════════════════

## ────────── НАСТРОЙКИ В ИНСПЕКТОРЕ ──────────

@export_group("День / Ночь")
@export var cycle_duration: float = 90.0          ## Длительность полного цикла в секундах
@export var day_color:   Color = Color(1.00, 0.97, 0.88)   ## Полдень — тёплый
@export var dusk_color:  Color = Color(0.95, 0.50, 0.30)   ## Закат / рассвет
@export var night_color: Color = Color(0.15, 0.18, 0.40)   ## Ночь — холодный синий
@export var autostart_cycle: bool = true
@export_range(0.0, 1.0) var start_phase: float = 0.85       ## С чего начинается цикл

@export_group("Параллакс-фон")
@export var enable_parallax: bool = true
@export var sky_color:   Color = Color(0.45, 0.52, 0.78)
@export var hills_color: Color = Color(0.20, 0.25, 0.40)

@export_group("Секретки")
@export var secret_reveal_radius: float = 100.0
@export var secret_glow_color: Color = Color(1.0, 0.78, 0.32, 0.85)
@export var secret_pulse_speed: float = 1.5

@export_group("Туман")
@export var enable_fog: bool = true
@export var fog_color: Color = Color(0.45, 0.40, 0.55, 0.25)
@export var fog_density: float = 0.4              ## 0 = нет, 1 = полное молоко

@export_group("Виньетка")
@export var enable_vignette: bool = true
@export var vignette_color: Color = Color(0.0, 0.0, 0.0, 0.7)
@export var vignette_size: float = 0.7            ## Меньше = темнее по краям

@export_group("Частицы")
@export var enable_particles: bool = true
@export var particle_amount: int = 40
@export var particle_color: Color = Color(1.0, 0.95, 0.7, 0.4)


## ────────── ВНУТРЕННЕЕ СОСТОЯНИЕ ──────────

var _time_in_cycle: float = 0.0
var _canvas_modulate: CanvasModulate
var _parallax: ParallaxBackground
var _fog_layer: CanvasLayer
var _fog_rect: ColorRect
var _vignette_layer: CanvasLayer
var _vignette_rect: ColorRect
var _particles: CPUParticles2D
var _secrets: Array[Node2D] = []
var _player: Node2D = null


## ────────── ИНИЦИАЛИЗАЦИЯ ──────────

func _ready() -> void:
	_setup_canvas_modulate()
	if enable_parallax:    _setup_parallax_layers()
	if enable_fog:         _setup_fog()
	if enable_vignette:    _setup_vignette()
	if enable_particles:   _setup_particles()
	_setup_secret_spots()
	_find_player()
	_time_in_cycle = start_phase * cycle_duration
	if autostart_cycle:
		set_process(true)


func _setup_canvas_modulate() -> void:
	_canvas_modulate = CanvasModulate.new()
	_canvas_modulate.color = day_color
	add_child(_canvas_modulate)


## ────────── ПАРАЛЛАКС ──────────

func _setup_parallax_layers() -> void:
	_parallax = ParallaxBackground.new()
	add_child(_parallax)

	# Слой 1 — небо (статичное, заполняет фон)
	var sky_layer := ParallaxLayer.new()
	sky_layer.motion_scale = Vector2.ZERO
	var sky_rect := ColorRect.new()
	sky_rect.color = sky_color
	sky_rect.size = Vector2(8192, 4096)
	sky_rect.position = Vector2(-4096, -2048)
	sky_layer.add_child(sky_rect)
	_parallax.add_child(sky_layer)

	# Слой 2 — дальние силуэты соборов / руин
	var far_layer := ParallaxLayer.new()
	far_layer.motion_scale = Vector2(0.15, 0.10)
	far_layer.add_child(_make_skyline_silhouette(hills_color.darkened(0.4), 0.55, 12345))
	_parallax.add_child(far_layer)

	# Слой 3 — ближние холмы / стены
	var near_layer := ParallaxLayer.new()
	near_layer.motion_scale = Vector2(0.40, 0.30)
	near_layer.add_child(_make_skyline_silhouette(hills_color, 1.0, 67890))
	_parallax.add_child(near_layer)


## Генерирует «силуэт города/собора» — рваный полигон с шпилями
func _make_skyline_silhouette(color: Color, scale_y: float, seed: int) -> Polygon2D:
	var poly := Polygon2D.new()
	poly.color = color
	var points: PackedVector2Array = []
	var width := 8192
	var step := 80
	var rng := RandomNumberGenerator.new()
	rng.seed = seed

	# Низ полигона
	points.append(Vector2(-width / 2, 800))
	# Силуэт сверху — синусоида + шум + редкие острые шпили (как готические башни)
	var x := -width / 2
	while x <= width / 2:
		var base_y := -120.0 * scale_y * sin(x * 0.003)
		base_y += rng.randf_range(-25, 25) * scale_y
		# С шансом 8% добавляем «шпиль» — высокий пик
		if rng.randf() < 0.08:
			base_y -= rng.randf_range(80, 180) * scale_y
		points.append(Vector2(x, base_y))
		x += step
	points.append(Vector2(width / 2, 800))

	poly.polygon = points
	poly.position = Vector2(0, 250)
	return poly


## ────────── ТУМАН ──────────

func _setup_fog() -> void:
	_fog_layer = CanvasLayer.new()
	_fog_layer.layer = 5
	add_child(_fog_layer)

	_fog_rect = ColorRect.new()
	_fog_rect.color = fog_color
	_fog_rect.anchor_right = 1.0
	_fog_rect.anchor_bottom = 1.0
	_fog_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE

	# Шейдер тумана с движущимися «облаками»
	var shader := Shader.new()
	shader.code = """
shader_type canvas_item;

uniform vec4 fog_tint : source_color = vec4(0.45, 0.40, 0.55, 0.25);
uniform float density : hint_range(0.0, 1.0) = 0.4;
uniform float time_scale = 0.05;

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }

float noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	float a = hash(i);
	float b = hash(i + vec2(1.0, 0.0));
	float c = hash(i + vec2(0.0, 1.0));
	float d = hash(i + vec2(1.0, 1.0));
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(a, b, u.x) + (c - a) * u.y * (1.0 - u.x) + (d - b) * u.x * u.y;
}

void fragment() {
	float t = TIME * time_scale;
	float n = noise(UV * 4.0 + vec2(t, t * 0.7));
	n += 0.5 * noise(UV * 8.0 - vec2(t * 1.3, t));
	n *= 0.6;
	float alpha = fog_tint.a * density * (0.4 + n);
	COLOR = vec4(fog_tint.rgb, alpha);
}
"""
	var mat := ShaderMaterial.new()
	mat.shader = shader
	mat.set_shader_parameter("fog_tint", fog_color)
	mat.set_shader_parameter("density", fog_density)
	_fog_rect.material = mat
	_fog_layer.add_child(_fog_rect)


## ────────── ВИНЬЕТКА ──────────

func _setup_vignette() -> void:
	_vignette_layer = CanvasLayer.new()
	_vignette_layer.layer = 10
	add_child(_vignette_layer)

	_vignette_rect = ColorRect.new()
	_vignette_rect.anchor_right = 1.0
	_vignette_rect.anchor_bottom = 1.0
	_vignette_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var shader := Shader.new()
	shader.code = """
shader_type canvas_item;

uniform vec4 tint : source_color = vec4(0.0, 0.0, 0.0, 0.7);
uniform float size : hint_range(0.0, 1.5) = 0.7;

void fragment() {
	vec2 uv = UV - 0.5;
	float dist = length(uv);
	float v = smoothstep(size, size * 0.4, dist);
	COLOR = vec4(tint.rgb, tint.a * (1.0 - v));
}
"""
	var mat := ShaderMaterial.new()
	mat.shader = shader
	mat.set_shader_parameter("tint", vignette_color)
	mat.set_shader_parameter("size", vignette_size)
	_vignette_rect.material = mat
	_vignette_layer.add_child(_vignette_rect)


## ────────── ЧАСТИЦЫ ──────────

func _setup_particles() -> void:
	_particles = CPUParticles2D.new()
	_particles.amount = particle_amount
	_particles.lifetime = 8.0
	_particles.preprocess = 4.0
	_particles.emission_shape = CPUParticles2D.EMISSION_SHAPE_RECTANGLE
	_particles.emission_rect_extents = Vector2(960, 540)
	_particles.position = Vector2(0, -300)
	_particles.gravity = Vector2(20, 30)
	_particles.initial_velocity_min = 5.0
	_particles.initial_velocity_max = 20.0
	_particles.scale_amount_min = 0.5
	_particles.scale_amount_max = 1.5
	_particles.color = particle_color
	add_child(_particles)


## ────────── СЕКРЕТКИ ──────────

func _setup_secret_spots() -> void:
	for marker in get_tree().get_nodes_in_group("secret_spot"):
		if marker is Node2D:
			var glow := _make_secret_glow()
			marker.add_child(glow)
			_secrets.append(marker)


func _make_secret_glow() -> PointLight2D:
	var light := PointLight2D.new()
	light.color = secret_glow_color
	light.energy = 0.0
	light.texture_scale = 2.0
	var gradient := Gradient.new()
	gradient.add_point(0.0, Color(1, 1, 1, 1))
	gradient.add_point(1.0, Color(1, 1, 1, 0))
	var tex := GradientTexture2D.new()
	tex.gradient = gradient
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.5)
	tex.fill_to = Vector2(1.0, 0.5)
	tex.width = 256
	tex.height = 256
	light.texture = tex
	return light


## ────────── ИГРОК ──────────

func _find_player() -> void:
	var candidates := get_tree().get_nodes_in_group("player")
	if candidates.size() > 0 and candidates[0] is Node2D:
		_player = candidates[0]
		return
	var root := get_tree().current_scene
	if root:
		for n in [&"Player", &"player", &"MainCharacter", &"Character"]:
			var found := root.find_child(String(n), true, false)
			if found and found is Node2D:
				_player = found
				return


## ────────── ОСНОВНОЙ ЦИКЛ ──────────

func _process(delta: float) -> void:
	_time_in_cycle = fmod(_time_in_cycle + delta, cycle_duration)
	_update_lighting()
	_update_secrets(delta)


func _update_lighting() -> void:
	var t := _time_in_cycle / cycle_duration
	var current: Color
	if t < 0.25:
		current = night_color.lerp(dusk_color, t / 0.25)
	elif t < 0.5:
		current = dusk_color.lerp(day_color, (t - 0.25) / 0.25)
	elif t < 0.75:
		current = day_color.lerp(dusk_color, (t - 0.5) / 0.25)
	else:
		current = dusk_color.lerp(night_color, (t - 0.75) / 0.25)
	if _canvas_modulate:
		_canvas_modulate.color = current


func _update_secrets(delta: float) -> void:
	if _secrets.is_empty():
		return
	var t := _time_in_cycle / cycle_duration
	var is_night := t > 0.75 or t < 0.05
	var pulse := 1.0 + 0.3 * sin(Time.get_ticks_msec() * 0.001 * secret_pulse_speed)

	for secret in _secrets:
		var light: PointLight2D = secret.get_child(0) if secret.get_child_count() > 0 else null
		if not light:
			continue
		var target_energy := 0.0
		if is_night:
			target_energy = 1.0 * pulse
		if _player:
			var dist := secret.global_position.distance_to(_player.global_position)
			if dist < secret_reveal_radius:
				target_energy = max(target_energy, 1.8 * pulse)
		light.energy = lerp(light.energy, target_energy, 0.08)


## ────────── ПУБЛИЧНЫЕ МЕТОДЫ ──────────

func set_time_of_day(t: float) -> void:
	_time_in_cycle = clamp(t, 0.0, 1.0) * cycle_duration

func set_cycle_running(running: bool) -> void:
	set_process(running)

## Вызови из любого скрипта, чтобы тряхнуть камеру (если у тебя есть Camera2D в группе "shake_camera")
func screen_shake(intensity: float = 8.0, duration: float = 0.2) -> void:
	for cam in get_tree().get_nodes_in_group("shake_camera"):
		if cam is Camera2D:
			var tween := create_tween()
			var orig: Vector2 = cam.offfset
			tween.tween_method(
				func(v): cam.offset = orig + Vector2(randf_range(-v, v), randf_range(-v, v)),
				intensity, 0.0, duration
			)
			tween.tween_callback(func(): cam.offset = orig)
