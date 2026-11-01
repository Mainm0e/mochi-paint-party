// The mochi's painted face, stacked from swappable layers on the GPU:
// shine, cheeks, mood marks, eyes (white art + mask tinted by eye_color) and mouth.
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_back;

#include "res://shaders/toon_common.gdshaderinc"

uniform sampler2D shine : source_color, filter_linear_mipmap;
uniform sampler2D cheeks : source_color, filter_linear_mipmap;
uniform sampler2D marks : source_color, filter_linear_mipmap;
uniform sampler2D eyes : source_color, filter_linear_mipmap;
uniform sampler2D eye_mask : filter_linear_mipmap;
uniform sampler2D mouth : source_color, filter_linear_mipmap;
uniform bool has_cheeks = true;
uniform bool has_marks = false;
uniform vec4 eye_color : source_color = vec4(0.353, 0.227, 0.227, 1.0);

vec4 over(vec4 dst, vec4 src) {
	float a = src.a + dst.a * (1.0 - src.a);
	vec3 c = (src.rgb * src.a + dst.rgb * dst.a * (1.0 - src.a)) / max(a, 1e-4);
	return vec4(c, a);
}

void fragment() {
	vec4 c = texture(shine, UV);
	if (has_cheeks) { c = over(c, texture(cheeks, UV)); }
	if (has_marks) { c = over(c, texture(marks, UV)); }
	vec4 e = texture(eyes, UV);
	e.rgb *= mix(vec3(1.0), eye_color.rgb, texture(eye_mask, UV).a);
	c = over(c, e);
	c = over(c, texture(mouth, UV));
	ALBEDO = toon_light(c.rgb, NORMAL, INV_VIEW_MATRIX);
	ALPHA = c.a;
}
