// Two-band toon surface with a faint rim. Doodle props tint per instance (instance `albedo`),
// mochi parts use the shared `base_color`.
shader_type spatial;
render_mode unshaded, cull_back;

#include "res://shaders/toon_common.gdshaderinc"

uniform vec4 base_color : source_color = vec4(1.0);
instance uniform vec4 albedo : source_color = vec4(1.0);
uniform float rim = 0.1;
uniform float wobble = 0.0;

void vertex() {
	if (wobble > 0.0) {
		VERTEX += wobble_offset(VERTEX) * wobble;
	}
}

void fragment() {
	vec3 c = toon_light(base_color.rgb * albedo.rgb, NORMAL, INV_VIEW_MATRIX);
	c += rim * smoothstep(0.55, 0.95, 1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0));
	ALBEDO = c;
}
