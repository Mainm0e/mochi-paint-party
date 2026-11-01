// Paper islands: off-white paper with a faint world-aligned grid on top, slightly shaded sides.
// `albedo` (per instance) tints the paper once the page has been painted.
shader_type spatial;
render_mode unshaded;

#include "res://shaders/toon_common.gdshaderinc"

uniform vec4 paper : source_color = vec4(0.973, 0.965, 0.941, 1.0);
uniform vec4 grid_color : source_color = vec4(0.43, 0.49, 0.65, 1.0);
uniform float grid = 1.25;
instance uniform vec4 albedo : source_color = vec4(1.0);

varying vec3 wpos;
varying vec3 wnorm;

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	wnorm = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	vec3 base = paper.rgb * albedo.rgb;
	float top = step(0.5, wnorm.y);
	vec2 cell = abs(fract(wpos.xz / grid - 0.5) - 0.5) * grid;   // world distance to the nearest grid line
	float aa = fwidth(wpos.x) + fwidth(wpos.z);
	float line = 1.0 - smoothstep(0.012, 0.012 + aa, min(cell.x, cell.y));
	vec3 c = mix(base, grid_color.rgb, line * 0.18 * top);
	ALBEDO = top > 0.5 ? c : toon_light(c, NORMAL, INV_VIEW_MATRIX) * 0.94;
}
