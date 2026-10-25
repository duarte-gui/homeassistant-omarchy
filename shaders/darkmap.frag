// Turns OpenStreetMap's light tiles dark, as Home Assistant's frontend does in
// a dark theme: lightness inverted, hue kept — water stays blue, parks green —
// then laid over the panel's own background colour, so the land is the panel.
//
// Rebuild after editing: /usr/lib/qt6/bin/qsb --qt6 -o darkmap.frag.qsb darkmap.frag
#version 440

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec4 background;
};

layout(binding = 1) uniform sampler2D source;

void main() {
    vec4 c = texture(source, qt_TexCoord0);
    vec3 rgb = c.a > 0.0 ? c.rgb / c.a : vec3(0.0);

    // Adding the same amount to every channel keeps hue and chroma; this
    // amount sends lightness L to 1 - L.
    float hi = max(rgb.r, max(rgb.g, rgb.b));
    float lo = min(rgb.r, min(rgb.g, rgb.b));
    vec3 dark = rgb + vec3(1.0 - hi - lo);

    // Muted colours read better at night.
    float grey = dot(dark, vec3(0.299, 0.587, 0.114));
    dark = mix(vec3(grey), dark, 0.6);

    vec3 bg = background.rgb;
    vec3 outRgb = bg + dark * (vec3(1.0) - bg) * 0.85;
    fragColor = vec4(outRgb * c.a, c.a) * qt_Opacity;
}
