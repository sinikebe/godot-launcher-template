shader_type canvas_item;
// Slow-drifting organic wash for the menu backdrop. Deliberately cheap:
// 4 octaves of value noise, no textures, no derivatives -- it has to stay
// affordable on the GL Compatibility renderer and low-end Android GPUs.

uniform vec3 deep_color : source_color = vec3(0.023, 0.055, 0.05);
uniform vec3 glow_color : source_color = vec3(0.06, 0.42, 0.34);
uniform vec3 rim_color : source_color = vec3(0.12, 0.70, 0.58);
uniform float drift_speed = 0.035;
uniform float intensity = 1.0;

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453123);
}

float value_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	float a = hash(i);
	float b = hash(i + vec2(1.0, 0.0));
	float c = hash(i + vec2(0.0, 1.0));
	float d = hash(i + vec2(1.0, 1.0));
	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

float fbm(vec2 p) {
	float total = 0.0;
	float amplitude = 0.5;
	for (int i = 0; i < 4; i++) {
		total += value_noise(p) * amplitude;
		p *= 2.02;
		amplitude *= 0.5;
	}
	return total;
}

void fragment() {
	// Correct for aspect so the blobs stay round on ultrawide and on phones.
	vec2 uv = UV;
	vec2 p = uv;
	p.x *= max(1.0, 1.0 / max(SCREEN_PIXEL_SIZE.y / SCREEN_PIXEL_SIZE.x, 0.0001));

	float t = TIME * drift_speed;
	float base = fbm(p * 2.6 + vec2(t, t * 0.55));
	float detail = fbm(p * 5.3 - vec2(t * 0.8, t * 1.2));

	// Membranes: the ridges where the two noise fields agree.
	float membrane = smoothstep(0.46, 0.86, base * 0.72 + detail * 0.46);

	// Light pooling toward the upper-centre, where the title sits.
	float falloff = smoothstep(1.05, 0.12, distance(uv, vec2(0.5, 0.42)));

	vec3 color = deep_color
		+ glow_color * membrane * 0.55 * intensity
		+ rim_color * falloff * 0.22 * intensity;

	// Vignette so the menu text always has a calm edge to sit against.
	float vignette = smoothstep(1.15, 0.35, distance(uv, vec2(0.5, 0.5)));
	color *= mix(0.55, 1.0, vignette);

	COLOR = vec4(color, 1.0);
}
