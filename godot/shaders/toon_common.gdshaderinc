// Shared bits for the paper-and-ink look: fixed two-band toon lighting and the hand-drawn wobble.

uniform vec3 light_dir = vec3(-0.45, 0.8, 0.55);           // world space, toward the light
uniform vec3 shadow_tint : source_color = vec3(0.87, 0.83, 0.92);

vec3 wobble_offset(vec3 p) {
	float n = sin(p.x * 7.1 + p.y * 3.3) * cos(p.z * 6.7 - p.y * 2.1) + sin(p.z * 4.3 + p.x * 5.9) * 0.5;
	return vec3(n, sin(p.x * 5.0 + p.z * 5.0) * 0.6, n * 0.8);
}

// base colour in, toon-lit colour out (NORMAL is view space in fragment()).
vec3 toon_light(vec3 base, vec3 view_normal, mat4 inv_view) {
	vec3 n = normalize((inv_view * vec4(view_normal, 0.0)).xyz);
	float lit = smoothstep(-0.04, 0.08, dot(n, normalize(light_dir)));
	return mix(base * shadow_tint, base, lit);
}
