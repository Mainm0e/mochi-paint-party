// A painted, transparent decal (the emote faces baked in Blender), toon-lit like the body under it.
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_back;

#include "res://shaders/toon_common.gdshaderinc"

uniform sampler2D art : source_color, filter_linear_mipmap;

void fragment() {
	vec4 c = texture(art, UV);
	ALBEDO = toon_light(c.rgb, NORMAL, INV_VIEW_MATRIX);
	ALPHA = c.a;
}
