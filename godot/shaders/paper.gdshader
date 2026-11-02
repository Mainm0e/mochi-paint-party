// Canvas ground: primed canvas with a fine woven texture (threads over-and-under) on top, slightly shaded
// sides. `albedo` (per instance) tints the canvas once that spot has been painted.
// (The file keeps its old name, paper.gdshader, so every scene and script still finds it.)
shader_type spatial;
render_mode unshaded;

#include "res://shaders/toon_common.gdshaderinc"

uniform vec4 paper : source_color = vec4(0.965, 0.949, 0.918, 1.0);   // primed canvas
uniform vec4 thread_color : source_color = vec4(0.62, 0.55, 0.45, 1.0);
uniform float weave = 0.09;        // metres per thread
uniform float grid = 1.25;         // (unused now; kept so older materials that set it still work)
instance uniform vec4 albedo : source_color = vec4(1.0);

varying vec3 wpos;
varying vec3 wnorm;

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	wnorm = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	vec3 base = paper.rgb * albedo.rgb;
	float top = step(0.5, wnorm.y);
	vec2 p = wpos.xz / weave;
	vec2 cell = floor(p);
	vec2 f = fract(p);
	// over/under: in each cell either the warp (along z) or the weft (along x) thread is on top
	float over = mod(cell.x + cell.y, 2.0);
	float warp = smoothstep(0.0, 0.45, f.x) * smoothstep(1.0, 0.55, f.x);
	float weft = smoothstep(0.0, 0.45, f.y) * smoothstep(1.0, 0.55, f.y);
	float thread = mix(weft, warp, over);
	float fibre = hash(cell) * 0.5 + hash(floor(p * 3.0)) * 0.5;   // slubby, uneven threads
	// fade the weave out with distance so it never shimmers
	float aa = fwidth(p.x) + fwidth(p.y);
	float k = (1.0 - smoothstep(0.35, 0.9, aa)) * top;
	float shade = (1.0 - thread) * 0.07 + fibre * 0.03;
	vec3 c = mix(base, thread_color.rgb * albedo.rgb, shade * k);
	ALBEDO = top > 0.5 ? c : toon_light(c, NORMAL, INV_VIEW_MATRIX) * 0.94;
}
