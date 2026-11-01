// Inverted-hull ink outline, used as a material's next_pass. `radial` pushes out from the mesh centre
// instead of along the normal, which keeps hard-edged boxes closed at the corners.
shader_type spatial;
render_mode unshaded, cull_front;

#include "res://shaders/toon_common.gdshaderinc"

uniform vec4 ink : source_color = vec4(0.122, 0.114, 0.141, 1.0);
uniform float thickness = 0.01;
uniform bool radial = false;
uniform float wobble = 0.0;

void vertex() {
	vec3 dir = radial ? normalize(VERTEX + vec3(0.0, 0.0001, 0.0)) : NORMAL;
	if (wobble > 0.0) {
		VERTEX += wobble_offset(VERTEX) * wobble;
	}
	// thicken with camera distance so the ink line keeps roughly the same on-screen weight
	float dist = length((MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).xyz);
	VERTEX += dir * thickness * clamp(dist / 2.0, 1.0, 3.0);
}

void fragment() {
	ALBEDO = ink.rgb;
}
