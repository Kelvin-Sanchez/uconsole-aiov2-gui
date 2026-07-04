extends Control

const RAIL_CTL := "/usr/local/bin/aiov2_ctl"
const PGREP := "/usr/bin/pgrep"
# First letter of each token is bracketed so pgrep -f can't match its own
# command line (the literal "[r]tl_" doesn't satisfy the regex), while a real
# process running e.g. rtl_tcp still matches. Avoids a self-match false positive.
const SDR_PROC := "[r]tl_|[s]drpp|[S]DRPP|[g]qrx|[C]ubicSDR|[d]ump1090"
const REFRESH_SEC := 4.0

const AVAILABLE_RAILS := ["SDR", "GPS", "LORA", "USB"]

# Short descriptive subtitle per rail (cosmetic).
const RAIL_SUB := {
	"SDR": "RTL-SDR - swradio0",
	"GPS": "u-blox - /dev/gps0",
	"LORA": "SX1262 - 915 MHz",
	"USB": "Internal bus - AC1200",
}
const RAIL_GPIO := {"SDR": "GPIO7", "GPS": "GPIO27", "LORA": "GPIO16", "USB": "GPIO23"}

# Network-adapter driver -> the switchable rail that powers it.
const DRIVER_FEED_RAIL := {"mt7921u": "USB", "mt7921": "USB"}

# Default per-rail launchable programs. Each entry: label, cmd, headless.
# `headless` (server / no window) is infrastructure for a future "headless-only"
# mode — rail_launchers() already filters on it when config.launch_headless_only.
# Seeded into config.launchers; users edit config.json to add/change programs.
const DEFAULT_LAUNCHERS := {
	"SDR": [
		{"label": "rtl_tcp", "cmd": "rtl_tcp -a 0.0.0.0", "headless": true},
		{"label": "rtl_power (FM scan)", "cmd": "rtl_power -f 88M:108M:100k -1 /tmp/rtl_power.csv", "headless": true},
		{"label": "gqrx", "cmd": "gqrx", "headless": false},
	],
}

var config := {
	"enabled_rails": AVAILABLE_RAILS.duplicate(),
	"management_interface": "",
	"launchers": DEFAULT_LAUNCHERS.duplicate(true),
	"launch_headless_only": false,
}

# ---- field-radio instrument palette ----
var pal := {
	"ground": Color("0A0E13"), "panel": Color("141C25"),
	"line": Color("263340"), "line_soft": Color("1E2833"),
	"text_hi": Color("DCE6EF"), "text_mid": Color("8A99A8"), "text_dim": Color("566270"),
	"accent": Color("2FB4CE"), "on": Color("46C08A"), "off": Color("566270"),
	"warn": Color("E0A63C"), "crit": Color("E5645E"), "protect": Color("5E9BE0"),
	"pill_bg": Color("0E151C"), "on_bg": Color("0E1A16"), "on_line": Color("2C5A49"),
	"warn_bg": Color("191408"), "warn_line": Color("4A3A1C"),
	"protect_bg": Color("0F1C29"), "protect_line": Color("2F537A"),
	"mgmt_panel": Color("111C28"), "mgmt_line": Color("274056"),
}

var mono: SystemFont
var sans: SystemFont

var iface_drivers := {}
var rail_widgets := {}       # rail -> {led, pill, toggle, tag, meas, meas_btn}
var _measure_thread: Thread
var _measure_busy := false
var content: VBoxContainer
var settings_layer: Control
var refresh_timer: Timer
var _hostname := ""
# Cached styleboxes keyed by on/off — these are static, so build once and share
# across all controls instead of reallocating every refresh.
var _sb_led := {}
var _sb_pill := {}
var _sb_knob := {}
var _sb_track := {}
# telemetry refs
var src_val: Label
var draw_val: Label
var temp_val: Label
var batt_val: Label
var batt_fill: ColorRect
var status_label: Label
var host_label: Label
var link_dot: Panel
var mgmt_pill: Label
var mgmt_led: Panel

const BATT_INNER := 138.0

func config_path() -> String:
	return OS.get_environment("HOME") + "/.config/radio-ui/config.json"

func _ready() -> void:
	mono = SystemFont.new()
	mono.font_names = PackedStringArray(["DejaVu Sans Mono", "Liberation Mono", "monospace"])
	sans = SystemFont.new()
	sans.font_names = PackedStringArray(["DejaVu Sans", "Noto Sans", "sans-serif"])

	theme = _build_theme()

	var bg := ColorRect.new()
	bg.color = pal.ground
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	# top signal hairline
	var hair := ColorRect.new()
	hair.color = pal.accent
	hair.anchor_right = 1.0
	hair.offset_bottom = 2
	add_child(hair)

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 26)
	margin.add_theme_constant_override("margin_top", 22)
	margin.add_theme_constant_override("margin_right", 26)
	margin.add_theme_constant_override("margin_bottom", 20)
	add_child(margin)

	content = VBoxContainer.new()
	content.add_theme_constant_override("separation", 16)
	margin.add_child(content)

	_hostname = host_name()   # cached: never changes at runtime
	load_config()
	detect_interfaces()
	build_ui()
	refresh_state()

	refresh_timer = Timer.new()
	refresh_timer.wait_time = REFRESH_SEC
	refresh_timer.autostart = true
	refresh_timer.timeout.connect(refresh_state)
	add_child(refresh_timer)

func _build_theme() -> Theme:
	var t := Theme.new()
	t.default_font = mono
	t.default_font_size = 14
	# buttons
	var b := _sb(pal.pill_bg, 8, 1, pal.line, 10, 20)
	var bh := _sb(Color("16202B"), 8, 1, pal.accent, 10, 20)
	t.set_stylebox("normal", "Button", b)
	t.set_stylebox("hover", "Button", bh)
	t.set_stylebox("pressed", "Button", bh)
	t.set_stylebox("focus", "Button", b)
	t.set_stylebox("disabled", "Button", b)
	t.set_color("font_color", "Button", pal.text_mid)
	t.set_color("font_hover_color", "Button", pal.accent)
	t.set_color("font_pressed_color", "Button", pal.accent)
	# cards
	t.set_stylebox("panel", "PanelContainer", _sb(pal.panel, 12, 1, pal.line_soft, 16, 16))
	t.set_color("font_color", "Label", pal.text_hi)
	return t

# StyleBoxFlat helper: bg, corner radius, border width+color, content margin h/v
func _sb(bg: Color, radius: float, bw: float = 0.0, bc: Color = Color(0,0,0,0), ch: float = 0.0, cv: float = 0.0) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.corner_radius_top_left = radius
	s.corner_radius_top_right = radius
	s.corner_radius_bottom_left = radius
	s.corner_radius_bottom_right = radius
	if bw > 0.0:
		s.border_width_left = bw
		s.border_width_top = bw
		s.border_width_right = bw
		s.border_width_bottom = bw
		s.border_color = bc
	if ch > 0.0 or cv > 0.0:
		s.content_margin_left = ch
		s.content_margin_right = ch
		s.content_margin_top = cv
		s.content_margin_bottom = cv
	return s

# ---------- config ----------
func load_config() -> void:
	var path := config_path()
	if not FileAccess.file_exists(path):
		return
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return
	var data = JSON.parse_string(f.get_as_text())
	f.close()
	if typeof(data) != TYPE_DICTIONARY:
		return
	if data.has("enabled_rails") and typeof(data["enabled_rails"]) == TYPE_ARRAY:
		var er := []
		for r in data["enabled_rails"]:
			if r in AVAILABLE_RAILS:
				er.append(r)
		config["enabled_rails"] = er
	if data.has("management_interface"):
		config["management_interface"] = str(data["management_interface"])
	if data.has("launchers") and typeof(data["launchers"]) == TYPE_DICTIONARY:
		config["launchers"] = data["launchers"]
	if data.has("launch_headless_only"):
		config["launch_headless_only"] = bool(data["launch_headless_only"])

func save_config() -> void:
	DirAccess.make_dir_recursive_absolute(OS.get_environment("HOME") + "/.config/radio-ui")
	var f := FileAccess.open(config_path(), FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify(config, "\t"))
	f.close()

# ---------- interface detection ----------
func detect_interfaces() -> void:
	iface_drivers.clear()
	var names_out := []
	OS.execute("ls", ["/sys/class/net"], names_out, true)
	if names_out.is_empty():
		return
	for nm in str(names_out[0]).split("\n", false):
		nm = nm.strip_edges()
		if nm == "" or nm == "lo":
			continue
		var drv := ""
		var link := []
		OS.execute("readlink", ["-f", "/sys/class/net/%s/device/driver" % nm], link, true)
		if not link.is_empty():
			var b := str(link[0]).strip_edges().get_file()
			if b != "" and b != "driver":
				drv = b
		iface_drivers[nm] = drv

func management_feed_rail() -> String:
	var mi: String = config.get("management_interface", "")
	if mi == "":
		return ""
	return DRIVER_FEED_RAIL.get(iface_drivers.get(mi, ""), "")

func iface_state(iface: String) -> String:
	if iface == "":
		return ""
	var out := []
	OS.execute("cat", ["/sys/class/net/%s/operstate" % iface], out, true)
	return "" if out.is_empty() else str(out[0]).strip_edges()

func iface_ip(iface: String) -> String:
	if iface == "":
		return ""
	var out := []
	OS.execute("ip", ["-4", "-o", "addr", "show", iface], out, true)
	if out.is_empty():
		return ""
	var t := str(out[0])
	var idx := t.find("inet ")
	if idx == -1:
		return ""
	return t.substr(idx + 5).strip_edges().split("/")[0].split(" ")[0]

func host_name() -> String:
	var out := []
	OS.execute("hostname", [], out, true)
	return "device" if out.is_empty() else str(out[0]).strip_edges()

func cpu_temp() -> float:
	var out := []
	OS.execute("cat", ["/sys/class/thermal/thermal_zone0/temp"], out, true)
	if out.is_empty():
		return -1.0
	return str(out[0]).strip_edges().to_float() / 1000.0

# rail -> whether it powers on at boot, parsed from `aiov2_ctl --boot-rails-status`
func boot_rails_status() -> Dictionary:
	var res := {}
	var out := []
	OS.execute(RAIL_CTL, ["--boot-rails-status"], out, true)
	if out.is_empty():
		return res
	for line in str(out[0]).split("\n", false):
		for r in AVAILABLE_RAILS:
			if line.find(r) != -1:
				res[r] = line.find("ON") != -1
	return res

# ---------- widget factories ----------
func _make_label(txt: String, size: int, col: Color, use_sans := false) -> Label:
	var l := Label.new()
	l.text = txt
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", col)
	if use_sans:
		l.add_theme_font_override("font", sans)
	return l

func _led_sb(on: bool) -> StyleBoxFlat:
	if _sb_led.has(on):
		return _sb_led[on]
	var s := _sb(pal.on if on else pal.off, 6)
	if on:
		s.shadow_color = Color(pal.on.r, pal.on.g, pal.on.b, 0.7)
		s.shadow_size = 6
	_sb_led[on] = s
	return s

func _make_led(on: bool) -> Panel:
	var p := Panel.new()
	p.custom_minimum_size = Vector2(12, 12)
	p.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	p.add_theme_stylebox_override("panel", _led_sb(on))
	return p

func _pill_sb(on: bool) -> StyleBoxFlat:
	if not _sb_pill.has(on):
		_sb_pill[on] = _sb(pal.on_bg, 6, 1, pal.on_line, 8, 3) if on else _sb(pal.pill_bg, 6, 1, pal.line, 8, 3)
	return _sb_pill[on]

func _make_pill(on: bool, txt: String) -> Label:
	var l := Label.new()
	l.text = txt
	l.add_theme_font_size_override("font_size", 14)
	l.add_theme_color_override("font_color", pal.on if on else pal.off)
	l.add_theme_stylebox_override("normal", _pill_sb(on))
	l.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return l

func _knob_sb(on: bool) -> StyleBoxFlat:
	if _sb_knob.has(on):
		return _sb_knob[on]
	var s := _sb(pal.on if on else pal.text_dim, 12)
	if on:
		s.shadow_color = Color(pal.on.r, pal.on.g, pal.on.b, 0.7)
		s.shadow_size = 6
	_sb_knob[on] = s
	return s

func _style_toggle(track: Button, on: bool) -> void:
	if not _sb_track.has(on):
		_sb_track[on] = _sb(pal.on_bg, 16, 1, pal.on_line) if on else _sb(pal.pill_bg, 16, 1, pal.line)
	var s: StyleBoxFlat = _sb_track[on]
	track.add_theme_stylebox_override("normal", s)
	track.add_theme_stylebox_override("hover", s)
	track.add_theme_stylebox_override("pressed", s)
	track.add_theme_stylebox_override("focus", s)

func _make_toggle(rail: String, on: bool) -> Button:
	var track := Button.new()
	track.custom_minimum_size = Vector2(64, 32)
	track.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	# Keep the track at its 32px height and centered — otherwise it vertical-fills
	# the (taller) button row and the fixed-position knob ends up stuck top-left.
	track.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	track.focus_mode = Control.FOCUS_NONE
	_style_toggle(track, on)
	var knob := Panel.new()
	knob.name = "knob"
	knob.custom_minimum_size = Vector2(24, 24)
	knob.size = Vector2(24, 24)
	knob.position = Vector2(36 if on else 4, 4)
	knob.mouse_filter = Control.MOUSE_FILTER_IGNORE
	knob.add_theme_stylebox_override("panel", _knob_sb(on))
	track.add_child(knob)
	track.pressed.connect(_on_toggle.bind(rail))
	return track

# ---------- main UI ----------
func build_ui() -> void:
	for c in content.get_children():
		c.queue_free()
	rail_widgets.clear()
	mgmt_pill = null
	mgmt_led = null

	content.add_child(_build_topbar())

	var rails := HBoxContainer.new()
	rails.add_theme_constant_override("separation", 14)
	rails.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var feed_rail := management_feed_rail()
	for r in config["enabled_rails"]:
		rails.add_child(_make_rail_card(r, feed_rail))
	var mi: String = config.get("management_interface", "")
	if mi != "":
		rails.add_child(_make_mgmt_card(mi))
	content.add_child(rails)

	content.add_child(_build_statusbar())

func _build_topbar() -> Control:
	var bar := HBoxContainer.new()

	var left := VBoxContainer.new()
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.add_theme_constant_override("separation", 5)
	var brand := _make_label("RADIO CONTROL", 24, pal.text_hi)
	left.add_child(brand)
	var host_row := HBoxContainer.new()
	host_row.add_theme_constant_override("separation", 8)
	link_dot = Panel.new()
	link_dot.custom_minimum_size = Vector2(9, 9)
	link_dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	link_dot.add_theme_stylebox_override("panel", _led_sb(true))
	host_row.add_child(link_dot)
	host_label = _make_label("", 13, pal.text_dim)
	host_row.add_child(host_label)
	left.add_child(host_row)
	bar.add_child(left)

	var tele := HBoxContainer.new()
	tele.add_theme_constant_override("separation", 26)
	tele.alignment = BoxContainer.ALIGNMENT_END
	src_val = _make_label("--", 22, pal.text_hi)
	tele.add_child(_metric("SOURCE", src_val))
	draw_val = _make_label("--", 22, pal.text_hi)
	tele.add_child(_metric("DRAW", draw_val))
	temp_val = _make_label("--", 22, pal.text_hi)
	tele.add_child(_metric("TEMP", temp_val))

	var batt_col := VBoxContainer.new()
	batt_col.add_theme_constant_override("separation", 5)
	batt_val = _make_label("--", 22, pal.on)
	batt_col.add_child(_metric("BATTERY", batt_val))
	var bar_bg := Panel.new()
	bar_bg.custom_minimum_size = Vector2(140, 12)
	bar_bg.size_flags_horizontal = Control.SIZE_SHRINK_END
	bar_bg.add_theme_stylebox_override("panel", _sb(Color("0d141b"), 6, 1, pal.line))
	batt_fill = ColorRect.new()
	batt_fill.color = pal.on
	batt_fill.position = Vector2(1, 1)
	batt_fill.size = Vector2(0, 10)
	bar_bg.add_child(batt_fill)
	batt_col.add_child(bar_bg)
	tele.add_child(batt_col)
	bar.add_child(tele)
	return bar

func _metric(label: String, val: Label) -> VBoxContainer:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 2)
	v.alignment = BoxContainer.ALIGNMENT_END
	var l := _make_label(label, 12, pal.text_dim)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	val.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	v.add_child(l)
	v.add_child(val)
	return v

func _make_rail_card(rail: String, feed_rail: String) -> PanelContainer:
	var card := PanelContainer.new()
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card.size_flags_vertical = Control.SIZE_EXPAND_FILL

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 8)
	card.add_child(vb)

	var head := HBoxContainer.new()
	var name_lbl := _make_label(rail, 26, pal.text_hi)
	name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(name_lbl)
	head.add_child(_make_label(RAIL_GPIO.get(rail, ""), 12, pal.text_dim))
	vb.add_child(head)

	vb.add_child(_make_label(RAIL_SUB.get(rail, ""), 13, pal.text_mid, true))

	var srow := HBoxContainer.new()
	srow.add_theme_constant_override("separation", 8)
	var led := _make_led(false)
	srow.add_child(led)
	var pill := _make_pill(false, "OFF")
	srow.add_child(pill)
	var tag := _make_label("", 11, pal.warn)
	tag.add_theme_stylebox_override("normal", _sb(pal.warn_bg, 4, 1, pal.warn_line, 5, 2))
	tag.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	tag.visible = false
	if rail == feed_rail:
		tag.text = "POWERS " + config["management_interface"].to_upper()
		tag.visible = true
	srow.add_child(tag)
	vb.add_child(srow)

	var meas := _make_label("", 12, pal.text_dim)
	vb.add_child(meas)

	# Launch control, centered in the card's free space: opens a menu of this
	# rail's configured programs (see rail_launchers / config.launchers).
	var spacer_top := Control.new()
	spacer_top.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vb.add_child(spacer_top)
	var launch := Button.new()
	launch.text = "Launch"
	launch.custom_minimum_size = Vector2(0, 34)
	launch.pressed.connect(_open_launch_menu.bind(rail))
	vb.add_child(launch)

	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vb.add_child(spacer)

	var bottom := HBoxContainer.new()
	var toggle := _make_toggle(rail, false)
	bottom.add_child(toggle)
	var bspace := Control.new()
	bspace.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bottom.add_child(bspace)
	var meas_btn := Button.new()
	meas_btn.text = "Meas"
	meas_btn.custom_minimum_size = Vector2(84, 32)
	meas_btn.add_theme_font_size_override("font_size", 13)
	meas_btn.pressed.connect(_measure_rail.bind(rail))
	bottom.add_child(meas_btn)
	vb.add_child(bottom)

	rail_widgets[rail] = {"led": led, "pill": pill, "toggle": toggle, "tag": tag, "meas": meas, "meas_btn": meas_btn, "is_feed": rail == feed_rail}
	return card

func _make_mgmt_card(mi: String) -> PanelContainer:
	var card := PanelContainer.new()
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card.size_flags_vertical = Control.SIZE_EXPAND_FILL
	card.add_theme_stylebox_override("panel", _sb(pal.mgmt_panel, 12, 1, pal.mgmt_line, 16, 16))

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 8)
	card.add_child(vb)

	var head := HBoxContainer.new()
	var name_lbl := _make_label(mi, 26, pal.text_hi)
	name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(name_lbl)
	head.add_child(_make_label(iface_drivers.get(mi, ""), 12, pal.text_dim))
	vb.add_child(head)

	vb.add_child(_make_label("Management link", 13, pal.text_mid, true))

	var srow := HBoxContainer.new()
	srow.add_theme_constant_override("separation", 8)
	mgmt_led = _make_led(false)
	srow.add_child(mgmt_led)
	mgmt_pill = _make_pill(false, "--")
	srow.add_child(mgmt_pill)
	vb.add_child(srow)

	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vb.add_child(spacer)

	var badge := _make_label("MANAGEMENT", 11, pal.protect)
	badge.add_theme_stylebox_override("normal", _sb(pal.protect_bg, 4, 1, pal.protect_line, 6, 3))
	badge.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	vb.add_child(badge)
	return card

func _build_statusbar() -> Control:
	var bar := HBoxContainer.new()
	status_label = _make_label("", 13, pal.text_dim)
	status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(status_label)

	var silence_btn := Button.new()
	silence_btn.text = "RF Silence"
	silence_btn.custom_minimum_size = Vector2(130, 40)
	silence_btn.add_theme_stylebox_override("normal", _sb(Color("1c0f10"), 8, 1, Color("6b2f2c"), 10, 20))
	silence_btn.add_theme_color_override("font_color", Color("E5645E"))
	silence_btn.pressed.connect(_rf_silence)
	bar.add_child(silence_btn)

	var settings_btn := Button.new()
	settings_btn.text = "Settings"
	settings_btn.custom_minimum_size = Vector2(120, 40)
	settings_btn.pressed.connect(open_settings)
	bar.add_child(settings_btn)

	var refresh := Button.new()
	refresh.text = "Refresh"
	refresh.custom_minimum_size = Vector2(120, 40)
	refresh.add_theme_stylebox_override("normal", _sb(Color("0c1a1e"), 8, 1, Color("245e6c"), 10, 20))
	refresh.add_theme_color_override("font_color", pal.accent)
	refresh.pressed.connect(refresh_state)
	bar.add_child(refresh)
	return bar

# ---------- refresh ----------
func refresh_state() -> void:
	var txt := run_cmd(RAIL_CTL, ["--status"])
	var lines := txt.split("\n")
	var on_map := {}
	for line in lines:
		for r in config["enabled_rails"]:
			if line.begins_with(r) and line.find("GPIO") != -1:
				on_map[r] = line.find("ON") != -1
	var sdr_on: bool = on_map.get("SDR", false)
	var sdr_busy := _sdr_in_use() if sdr_on else false   # skip pgrep when SDR is off
	for r in config["enabled_rails"]:
		var on: bool = on_map.get(r, false)
		update_rail_visual(r, on, on and r == "SDR" and sdr_busy)

	var cap := ""
	for line in lines:
		if line.begins_with("Capacity"):
			cap = line.get_slice(":", 1).strip_edges()
		elif line.begins_with("Power") and draw_val:
			draw_val.text = line.get_slice(":", 1).strip_edges()
		elif line.begins_with("Source") and src_val:
			src_val.text = line.get_slice(":", 1).strip_edges()
	if batt_val and cap != "":
		var pct := cap.to_int()
		var on_ac := src_val != null and src_val.text.begins_with("AC")
		var low := pct <= 20 and not on_ac   # only alarming when actually discharging
		batt_val.text = cap
		batt_val.add_theme_color_override("font_color", pal.crit if low else pal.on)
		if batt_fill:
			batt_fill.size = Vector2(BATT_INNER * float(pct) / 100.0, 10)
			batt_fill.color = pal.crit if low else pal.on
	if temp_val:
		var tc := cpu_temp()
		if tc >= 0.0:
			temp_val.text = "%d°C" % int(round(tc))
			temp_val.add_theme_color_override("font_color", pal.crit if tc >= 75.0 else (pal.warn if tc >= 65.0 else pal.text_hi))

	var mi: String = config.get("management_interface", "")
	var mstate := iface_state(mi) if mi != "" else ""   # read operstate once
	var mup := mstate == "up"
	if mgmt_pill and mi != "":
		mgmt_pill.text = mstate.to_upper() if mstate != "" else "?"
		mgmt_pill.add_theme_color_override("font_color", pal.on if mup else pal.warn)
		mgmt_pill.add_theme_stylebox_override("normal", _pill_sb(mup))
		if mgmt_led:
			mgmt_led.add_theme_stylebox_override("panel", _led_sb(mup))

	if host_label:
		var ip := iface_ip(mi)
		host_label.text = "%s - %s %s" % [_hostname, mi, ip] if mi != "" else _hostname
		if link_dot:
			link_dot.add_theme_stylebox_override("panel", _led_sb(mup))

	if status_label:
		status_label.text = "auto-refresh %ds - updated %s" % [int(REFRESH_SEC), Time.get_time_string_from_system()]

func update_rail_visual(rail: String, on: bool, in_use: bool) -> void:
	var w = rail_widgets.get(rail)
	if w == null:
		return
	w.led.add_theme_stylebox_override("panel", _led_sb(on))
	w.pill.text = "ON" if on else "OFF"
	w.pill.add_theme_color_override("font_color", pal.on if on else pal.off)
	w.pill.add_theme_stylebox_override("normal", _pill_sb(on))
	_style_toggle(w.toggle, on)
	var knob = w.toggle.get_node("knob")
	knob.position = Vector2(36 if on else 4, 4)
	knob.add_theme_stylebox_override("panel", _knob_sb(on))
	if not w.is_feed:
		w.tag.text = "IN USE"
		w.tag.visible = in_use

# ---------- toggle + guards ----------
func _on_toggle(rail: String) -> void:
	var w = rail_widgets.get(rail)
	var cur: String = w.pill.text if w else "?"
	var action := "off" if cur == "ON" else "on"
	if action == "off":
		if rail == management_feed_rail():
			_confirm("Warning: management link",
				"The %s rail powers your management interface (%s).\nPowering it off will drop your connection.\nContinue?" % [rail, config["management_interface"]],
				rail)
			return
		if rail == "SDR" and _sdr_in_use():
			_confirm("Warning: SDR in use",
				"SDR is in use by a running tool.\nPowering it off will kill that tool.\nContinue?",
				rail)
			return
	_do_action(rail, action)

func _confirm(dtitle: String, body: String, rail: String, action: String = "off") -> void:
	var d := ConfirmationDialog.new()
	d.title = dtitle
	d.dialog_text = body
	add_child(d)
	d.confirmed.connect(_do_action.bind(rail, action))
	d.confirmed.connect(d.queue_free)
	d.canceled.connect(d.queue_free)
	d.popup_centered()

func _do_action(rail: String, action: String) -> void:
	run_cmd(RAIL_CTL, [rail, action])
	refresh_state()

# Cut every enabled rail except the one feeding the management interface.
func _rf_silence() -> void:
	var feed := management_feed_rail()
	for r in config["enabled_rails"]:
		if r != feed:
			run_cmd(RAIL_CTL, [r, "off"])
	refresh_state()

func _sdr_in_use() -> bool:
	var out := []
	OS.execute(PGREP, ["-f", SDR_PROC], out, true)
	return not (out.is_empty() or str(out[0]).strip_edges() == "")

# Configured launchers for a rail, filtered to headless entries when the
# headless-only mode is on (infrastructure for the future toggle).
func rail_launchers(rail: String) -> Array:
	var list: Array = config.get("launchers", {}).get(rail, [])
	if not config.get("launch_headless_only", false):
		return list
	var filtered := []
	for l in list:
		if l.get("headless", false):
			filtered.append(l)
	return filtered

# Process name pgrep -x matches: basename of the command's first token.
func _proc_name(cmd: String) -> String:
	var toks := cmd.strip_edges().split(" ", false)
	return "" if toks.is_empty() else str(toks[0]).get_file()

func _proc_running(pname: String) -> bool:
	if pname == "":
		return false
	var out := []
	OS.execute(PGREP, ["-x", pname], out, true)
	if out.is_empty():
		return false
	for pid in str(out[0]).split("\n", false):
		pid = pid.strip_edges()
		if pid == "":
			continue
		var st := []
		OS.execute("cat", ["/proc/%s/stat" % pid], st, true)
		if st.is_empty():
			continue
		# stat = "PID (comm) STATE ..."; comm may contain spaces, so read after the last ')'
		var s := str(st[0])
		if s.substr(s.rfind(")") + 1).strip_edges().split(" ")[0] != "Z":  # skip zombies
			return true
	return false

func _open_launch_menu(rail: String) -> void:
	if settings_layer != null:
		return
	settings_layer = Control.new()
	settings_layer.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(settings_layer)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.6)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	settings_layer.add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	settings_layer.add_child(center)
	var panel := PanelContainer.new()
	center.add_child(panel)
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	vbox.custom_minimum_size = Vector2(460, 0)
	panel.add_child(vbox)

	vbox.add_child(_make_label("LAUNCH - %s" % rail, 22, pal.text_hi))
	var launchers := rail_launchers(rail)
	if launchers.is_empty():
		vbox.add_child(_make_label("No programs configured for this rail.\nAdd them under \"launchers\" in config.json.", 13, pal.text_dim, true))
	for l in launchers:
		var cmd := str(l["cmd"])
		var running := _proc_running(_proc_name(cmd))
		var b := Button.new()
		b.text = ("Stop " if running else "Launch ") + str(l["label"])
		b.custom_minimum_size = Vector2(0, 44)
		if running:
			b.add_theme_color_override("font_color", pal.on)
		b.pressed.connect(_launch_run.bind(rail, cmd))
		vbox.add_child(b)

	var cancel := Button.new()
	cancel.text = "Cancel"
	cancel.custom_minimum_size = Vector2(0, 44)
	cancel.pressed.connect(close_settings)
	vbox.add_child(cancel)

func _launch_run(rail: String, cmd: String) -> void:
	var pname := _proc_name(cmd)
	if _proc_running(pname):
		OS.execute("pkill", ["-x", pname], [], true)
	else:
		if rail in AVAILABLE_RAILS:
			run_cmd(RAIL_CTL, [rail, "on"])   # power the rail so its tools have a device
		# --fork reparents to init (reaped cleanly on stop); sleep lets USB devices enumerate
		OS.create_process("setsid", ["--fork", "sh", "-c", "sleep 2; exec %s >/dev/null 2>&1" % cmd])
	close_settings()
	refresh_state()

# ---------- per-rail power measurement (threaded) ----------
func _measure_rail(rail: String) -> void:
	if _measure_busy:
		return
	var w = rail_widgets.get(rail)
	if w == null:
		return
	_measure_busy = true
	if refresh_timer:
		refresh_timer.stop()   # avoid a second aiov2_ctl on the I2C bus mid-measure
	w.meas.add_theme_color_override("font_color", pal.warn)
	w.meas.text = "measuring..."
	w.meas_btn.disabled = true
	_measure_thread = Thread.new()
	_measure_thread.start(_measure_worker.bind(rail))

func _measure_worker(rail: String) -> void:
	var out := []
	OS.execute(RAIL_CTL, ["--measure", rail, "--seconds", "2"], out, true)
	call_deferred("_measure_done", rail, "" if out.is_empty() else str(out[0]))

func _measure_done(rail: String, txt: String) -> void:
	if _measure_thread:
		_measure_thread.wait_to_finish()
	_measure_busy = false
	if refresh_timer:
		refresh_timer.start()   # resume polling now the bus is free
	var w = rail_widgets.get(rail)
	if w == null:
		return
	w.meas_btn.disabled = false
	var on_w := 0.0
	var off_w := 0.0
	var got := false
	for line in txt.split("\n"):
		line = line.strip_edges()
		if line.begins_with("ON"):
			on_w = line.get_slice(":", 1).strip_edges().to_float()
			got = true
		elif line.begins_with("OFF"):
			off_w = line.get_slice(":", 1).strip_edges().to_float()
	if got:
		w.meas.add_theme_color_override("font_color", pal.text_mid)
		w.meas.text = "draw %+.2f W" % (on_w - off_w)
	else:
		w.meas.add_theme_color_override("font_color", pal.warn)
		w.meas.text = "measure failed"

# ---------- settings overlay ----------
func open_settings() -> void:
	if settings_layer != null:
		return
	detect_interfaces()

	settings_layer = Control.new()
	settings_layer.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(settings_layer)

	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.6)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	settings_layer.add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	settings_layer.add_child(center)

	var panel := PanelContainer.new()
	center.add_child(panel)
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	vbox.custom_minimum_size = Vector2(680, 0)
	panel.add_child(vbox)

	vbox.add_child(_make_label("SETTINGS", 22, pal.text_hi))
	vbox.add_child(_make_label("Show rails", 14, pal.text_dim))

	var grid := GridContainer.new()
	grid.columns = 4
	var rail_checks := {}
	for r in AVAILABLE_RAILS:
		var cb := CheckBox.new()
		cb.text = r
		cb.button_pressed = r in config["enabled_rails"]
		cb.add_theme_font_size_override("font_size", 18)
		rail_checks[r] = cb
		grid.add_child(cb)
	vbox.add_child(grid)

	vbox.add_child(_make_label("Management interface (protected)", 14, pal.text_dim))
	var opt := OptionButton.new()
	opt.custom_minimum_size = Vector2(0, 40)
	opt.add_item("(none)")
	opt.set_item_metadata(0, "")
	var iface_names := iface_drivers.keys()
	iface_names.sort()
	var sel_idx := 0
	for i in range(iface_names.size()):
		var nm: String = iface_names[i]
		var drv: String = iface_drivers[nm]
		opt.add_item("%s  [%s]" % [nm, drv] if drv != "" else nm)
		opt.set_item_metadata(i + 1, nm)
		if nm == config.get("management_interface", ""):
			sel_idx = i + 1
	opt.selected = sel_idx
	vbox.add_child(opt)

	vbox.add_child(_make_label("Power on at boot", 14, pal.text_dim))
	var boot_grid := GridContainer.new()
	boot_grid.columns = 4
	var boot_now := boot_rails_status()
	var boot_checks := {}
	for r in AVAILABLE_RAILS:
		var cb := CheckBox.new()
		cb.text = r
		cb.button_pressed = boot_now.get(r, false)
		cb.add_theme_font_size_override("font_size", 18)
		boot_checks[r] = cb
		boot_grid.add_child(cb)
	vbox.add_child(boot_grid)

	var btns := HBoxContainer.new()
	btns.add_theme_constant_override("separation", 16)
	var rtc_btn := Button.new()
	rtc_btn.text = "Sync RTC"
	rtc_btn.custom_minimum_size = Vector2(140, 44)
	rtc_btn.pressed.connect(func():
		OS.execute("sudo", ["/usr/local/bin/aiov2_ctl", "--sync-rtc"], [], true)
		rtc_btn.text = "RTC synced"
	)
	btns.add_child(rtc_btn)
	var bspace := Control.new()
	bspace.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btns.add_child(bspace)
	var cancel_btn := Button.new()
	cancel_btn.text = "Cancel"
	cancel_btn.custom_minimum_size = Vector2(130, 44)
	cancel_btn.pressed.connect(close_settings)
	btns.add_child(cancel_btn)
	var save_btn := Button.new()
	save_btn.text = "Save"
	save_btn.custom_minimum_size = Vector2(130, 44)
	save_btn.add_theme_stylebox_override("normal", _sb(Color("0c1a1e"), 8, 1, Color("245e6c"), 10, 20))
	save_btn.add_theme_color_override("font_color", pal.accent)
	save_btn.pressed.connect(func():
		var er := []
		for rr in AVAILABLE_RAILS:
			if rail_checks[rr].button_pressed:
				er.append(rr)
		config["enabled_rails"] = er
		var meta = opt.get_item_metadata(opt.selected)
		config["management_interface"] = str(meta) if meta != null else ""
		for rr in AVAILABLE_RAILS:
			run_cmd(RAIL_CTL, ["--boot-rail", rr, "on" if boot_checks[rr].button_pressed else "off"])
		save_config()
		close_settings()
		build_ui()
		refresh_state()
	)
	btns.add_child(save_btn)
	vbox.add_child(btns)

func close_settings() -> void:
	if settings_layer != null:
		settings_layer.queue_free()
		settings_layer = null

func _exit_tree() -> void:
	if _measure_thread and _measure_thread.is_started():
		_measure_thread.wait_to_finish()

# ---------- shell helper ----------
func run_cmd(path: String, args: PackedStringArray) -> String:
	var out := []
	OS.execute(path, args, out, true)
	return "" if out.is_empty() else str(out[0])
