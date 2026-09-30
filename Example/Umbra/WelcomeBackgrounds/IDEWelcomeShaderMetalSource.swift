enum IDEWelcomeShaderMetalSource {
    static let library = """
    #include <metal_stdlib>
    using namespace metal;

    struct VertexOut {
        float4 position [[position]];
        float2 uv;
    };

    vertex VertexOut welcomeVertex(uint id [[vertex_id]]) {
        float2 corner = float2((id << 1) & 2, id & 2);
        VertexOut out;
        out.position = float4(corner * 2.0 - 1.0, 0.0, 1.0);
        out.uv = float2(corner.x, 1.0 - corner.y);
        return out;
    }

    // -------------------------------------------------------------------------
    // Gradient Waves (React Bits GradientWaves.tsx)
    // -------------------------------------------------------------------------

    struct GradientWavesUniforms {
        float2 resolution;
        float time;
        float speed;
        float amplitude;
        float waveScale;
        float waveRatio;
        float swell;
        float turbulence;
        float tilt;
        float zoom;
        float height;
        float fogDepth;
        float steps;
        float brightness;
        float opacity;
        float grain;
        float grainIntensity;
        float enableMouse;
        float2 mouse;
        float parallax;
        float _pad0;
        float3 horizonColor;
        float _pad1;
        float3 waveColor;
        float _pad2;
        float3 crestColor;
        float _pad3;
    };

    constant float kGradientWavesMaxDist = 20000.0;

    inline float gw_hash21(float2 p) {
        float3 p3 = fract(float3(p.xyx) * 0.1031);
        p3 += dot(p3, p3.yzx + 33.33);
        return fract((p3.x + p3.y) * p3.z);
    }

    inline float gw_plasma(float3 r, float2 freq, float4 tc, constant GradientWavesUniforms &u) {
        float mx = r.x + tc.x;
        mx += u.swell * sin((r.y + mx) / 20.0 + tc.y);
        float my = r.y - tc.z;
        my += u.turbulence * cos(r.x / 23.0 + tc.w);
        return r.z - (sin(mx * freq.x) * u.amplitude + sin(my * freq.y) * u.amplitude + u.height);
    }

    inline float gw_raymarch(float3 pos, float3 dir, float2 freq, float4 tc, constant GradientWavesUniforms &u) {
        float dist = 0.0;
        for (int i = 0; i < 128; ++i) {
            if (float(i) >= u.steps) break;
            float dscene = gw_plasma(pos + dist * dir, freq, tc, u);
            if (abs(dscene) < 0.1) break;
            dist += 0.9 * dscene;
            if (!(abs(dist) < kGradientWavesMaxDist)) return kGradientWavesMaxDist;
        }
        return dist;
    }

    fragment float4 gradientWavesFragment(
        VertexOut in [[stage_in]],
        constant GradientWavesUniforms &u [[buffer(0)]]
    ) {
        float T = u.time * u.speed;
        float2 freq = float2(u.waveScale / 7.0, (u.waveScale * u.waveRatio) / 3.0);
        float4 tc = float4(T / 0.130, T / 0.810, T / 0.200, T / 0.710);
        float c, s;
        float vfov = (3.14159 / 2.3) / max(u.zoom, 0.05);
        float3 cam = float3(0.0, 0.0, 30.0);
        float2 res = u.resolution;
        float2 uv = (in.position.xy / res) - 0.5;
        uv.x *= res.x / res.y;
        uv.y *= -1.0;

        float3 dir = float3(0.0, 0.0, -1.0);
        float ulen = length(uv);
        float xrot = vfov * ulen;
        c = cos(xrot); s = sin(xrot);
        dir = float3x3(float3(1.0, 0.0, 0.0), float3(0.0, c, -s), float3(0.0, s, c)) * dir;
        float2 nuv = ulen > 1e-5 ? uv / ulen : float2(1.0, 0.0);
        c = nuv.x; s = nuv.y;
        dir = float3x3(float3(c, -s, 0.0), float3(s, c, 0.0), float3(0.0, 0.0, 1.0)) * dir;
        c = cos(u.tilt); s = sin(u.tilt);
        dir = float3x3(float3(c, 0.0, s), float3(0.0, 1.0, 0.0), float3(-s, 0.0, c)) * dir;

        if (u.enableMouse > 0.5) {
            float yaw = (u.mouse.x - 0.5) * u.parallax * 0.4;
            float pitch = (u.mouse.y - 0.5) * u.parallax * 0.4;
            c = cos(yaw); s = sin(yaw);
            dir = float3x3(float3(c, 0.0, s), float3(0.0, 1.0, 0.0), float3(-s, 0.0, c)) * dir;
            c = cos(pitch); s = sin(pitch);
            dir = float3x3(float3(1.0, 0.0, 0.0), float3(0.0, c, -s), float3(0.0, s, c)) * dir;
        }

        float dist = gw_raymarch(cam, dir, freq, tc, u);
        float3 pos = cam + dist * dir;

        float t = clamp(u.fogDepth / max(dist, 0.001), 0.0, 1.0);
        float3 body = mix(u.waveColor, u.crestColor, clamp(pos.z * 0.08 + 0.5, 0.0, 1.0));
        float3 col = mix(u.horizonColor, body, t);
        col *= u.brightness;
        col = clamp(col, 0.0, 1.0);

        float alpha = clamp(t, 0.0, 1.0) * u.opacity;
        if (u.grain > 0.5) {
            float g = gw_hash21(in.position.xy + fmod(u.time, 64.0) * 11.0);
            alpha += (g - 0.5) * u.grainIntensity;
        }
        alpha = clamp(alpha, 0.0, 1.0);
        return float4(col * alpha, alpha);
    }

    // -------------------------------------------------------------------------
    // Molten Metal (React Bits MoltenMetal.tsx)
    // -------------------------------------------------------------------------

    struct MoltenMetalUniforms {
        float2 resolution;
        float time;
        float speed;
        float scale;
        float detail;
        float glow;
        float coreSize;
        float swirl;
        float fold;
        float blackPoint;
        float brightness;
        float colorMode;
        float grain;
        float grainIntensity;
        float opacity;
        float mouseStrength;
        float enableMouse;
        float lightMode;
        float2 mouse;
        float _pad0;
        float3 color1;
        float _pad1;
        float3 color2;
        float _pad2;
        float3 color3;
        float _pad3;
        float3 backgroundColor;
        float _pad4;
    };

    inline float mm_hash(float2 p) {
        return fract(sin(dot(p, float2(12.9898, 78.233))) * 43758.5453);
    }

    fragment float4 moltenMetalFragment(
        VertexOut in [[stage_in]],
        constant MoltenMetalUniforms &u [[buffer(0)]]
    ) {
        float time = u.time * u.speed;
        float2 res = u.resolution;
        float2 p = u.scale * ((in.position.xy - 0.5 * res) / res.y) - 0.5;

        float2 drift = float2(0.0);
        if (u.enableMouse > 0.5) {
            drift = (u.mouse - 0.5) * u.mouseStrength * 2.0;
        }
        p += drift;

        float2 i = p;
        float c = 0.0;
        float r = length(p + float2(sin(time), sin(time * 0.3 + 5.0)) * 0.5);
        float d = length(p);
        float rot = d + time + p.x * u.swirl;

        float cosRot = cos(rot);
        float2x2 warp = float2x2(
            float2(cos(rot - sin(time / 5.0)), sin(rot)),
            float2(-sin(cosRot - time), cosRot)
        ) * u.fold;
        float glowCore = u.glow * u.coreSize;

        for (float n = 0.0; n < 8.0; n += 1.0) {
            if (n >= u.detail) break;
            p = warp * p;
            float t = r - time / (n + 3.0);
            i -= p + float2(cos(t - i.x - r) + sin(t + i.y), sin(t - i.y) + cos(t + i.x) + r);
            c += glowCore / length(float2(sin(i.x + t), cos(i.y + t)));
        }

        c /= 6.0;

        float intensity = max(c - u.blackPoint, 0.0) * u.brightness;
        float g = clamp(intensity, 0.0, 1.0);

        float mid = 0.5;
        if (u.colorMode > 1.5) {
            mid = 0.65;
        } else if (u.colorMode > 0.5) {
            mid = 0.35;
        }

        float3 col = mix(u.color1, u.color2, smoothstep(0.0, mid, g));
        col = mix(col, u.color3, smoothstep(mid, 1.0, g));

        float a = g;
        if (u.grain > 0.5) {
            float gr = mm_hash(in.position.xy + u.time);
            a += (gr - 0.5) * u.grainIntensity;
        }
        a = clamp(a, 0.0, 1.0) * u.opacity;
        if (u.lightMode > 0.5) {
            float signal = 1.0 - exp(-max(c, 0.0) * 6.5);
            float body = smoothstep(0.075, 0.68, signal);
            float ridge = smoothstep(0.42, 0.92, signal);

            float3 lightCol = mix(u.color1, u.color2, smoothstep(0.08, 0.52, signal));
            lightCol = mix(lightCol, u.color3, smoothstep(0.52, 0.96, signal));
            lightCol = mix(lightCol, lightCol * 0.72, ridge * 0.24);

            float coverage = body * mix(0.2, 0.86, signal) * u.opacity;
            if (u.grain > 0.5) {
                float gr = mm_hash(in.position.xy + u.time);
                coverage += (gr - 0.5) * u.grainIntensity * body * 0.16;
            }
            return float4(mix(u.backgroundColor, lightCol, clamp(coverage, 0.0, 0.92)), 1.0);
        }
        return float4(col * a, a);
    }

    // -------------------------------------------------------------------------
    // Galaxy (React Bits Galaxy.tsx)
    // -------------------------------------------------------------------------

    struct GalaxyUniforms {
        float3 resolution;
        float time;
        float2 focal;
        float2 rotation;
        float starSpeed;
        float density;
        float hueShift;
        float speed;
        float2 mouse;
        float glowIntensity;
        float saturation;
        float mouseRepulsion;
        float twinkleIntensity;
        float rotationSpeed;
        float repulsionStrength;
        float mouseActiveFactor;
        float autoCenterRepulsion;
        float transparent;
        float lightMode;
        float _pad0;
    };

    constant float kGalaxyNumLayer = 4.0;
    constant float kGalaxyStarColorCutoff = 0.2;
    constant float2x2 kGalaxyMat45 = float2x2(float2(0.7071, -0.7071), float2(0.7071, 0.7071));
    constant float kGalaxyPeriod = 3.0;

    inline float galaxy_Hash21(float2 p) {
        p = fract(p * float2(123.34, 456.21));
        p += dot(p, p + 45.32);
        return fract(p.x * p.y);
    }

    inline float galaxy_tri(float x) {
        return abs(fract(x) * 2.0 - 1.0);
    }

    inline float galaxy_tris(float x) {
        float t = fract(x);
        return 1.0 - smoothstep(0.0, 1.0, abs(2.0 * t - 1.0));
    }

    inline float galaxy_trisn(float x) {
        float t = fract(x);
        return 2.0 * (1.0 - smoothstep(0.0, 1.0, abs(2.0 * t - 1.0))) - 1.0;
    }

    inline float3 galaxy_hsv2rgb(float3 c) {
        float4 K = float4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
        float3 p = abs(fract(c.xxx + K.xyz) * 6.0 - K.www);
        return c.z * mix(K.xxx, clamp(p - K.xxx, 0.0, 1.0), c.y);
    }

    inline float galaxy_Star(float2 uv, float flare, float glowIntensity) {
        float d = length(uv);
        float m = (0.05 * glowIntensity) / d;
        float rays = smoothstep(0.0, 1.0, 1.0 - abs(uv.x * uv.y * 1000.0));
        m += rays * flare * glowIntensity;
        uv = kGalaxyMat45 * uv;
        rays = smoothstep(0.0, 1.0, 1.0 - abs(uv.x * uv.y * 1000.0));
        m += rays * 0.3 * flare * glowIntensity;
        m *= smoothstep(1.0, 0.2, d);
        return m;
    }

    inline float3 galaxy_StarLayer(float2 uv, constant GalaxyUniforms &u) {
        float3 col = float3(0.0);
        float2 gv = fract(uv) - 0.5;
        float2 id = floor(uv);

        for (int y = -1; y <= 1; ++y) {
            for (int x = -1; x <= 1; ++x) {
                float2 offset = float2(float(x), float(y));
                float2 si = id + float2(float(x), float(y));
                float seed = galaxy_Hash21(si);
                float size = fract(seed * 345.32);
                float glossLocal = galaxy_tri(u.starSpeed / (kGalaxyPeriod * seed + 1.0));
                float flareSize = smoothstep(0.9, 1.0, size) * glossLocal;

                float red = smoothstep(kGalaxyStarColorCutoff, 1.0, galaxy_Hash21(si + 1.0)) + kGalaxyStarColorCutoff;
                float blu = smoothstep(kGalaxyStarColorCutoff, 1.0, galaxy_Hash21(si + 3.0)) + kGalaxyStarColorCutoff;
                float grn = min(red, blu) * seed;
                float3 base = float3(red, grn, blu);

                float hue = atan2(base.g - base.r, base.b - base.r) / (2.0 * 3.14159) + 0.5;
                hue = fract(hue + u.hueShift / 360.0);
                float sat = length(base - float3(dot(base, float3(0.299, 0.587, 0.114)))) * u.saturation;
                float val = max(max(base.r, base.g), base.b);
                base = galaxy_hsv2rgb(float3(hue, sat, val));

                float2 pad = float2(
                    galaxy_tris(seed * 34.0 + u.time * u.speed / 10.0),
                    galaxy_tris(seed * 38.0 + u.time * u.speed / 30.0)
                ) - 0.5;

                float star = galaxy_Star(gv - offset - pad, flareSize, u.glowIntensity);
                float3 color = base;

                float twinkle = galaxy_trisn(u.time * u.speed + seed * 6.2831) * 0.5 + 1.0;
                twinkle = mix(1.0, twinkle, u.twinkleIntensity);
                star *= twinkle;

                col += star * size * color;
            }
        }
        return col;
    }

    fragment float4 galaxyFragment(
        VertexOut in [[stage_in]],
        constant GalaxyUniforms &u [[buffer(0)]]
    ) {
        float2 focalPx = u.focal * u.resolution.xy;
        float2 uv = (in.uv * u.resolution.xy - focalPx) / u.resolution.y;

        float2 mouseNorm = u.mouse - float2(0.5);

        if (u.autoCenterRepulsion > 0.0) {
            float2 centerUV = float2(0.0, 0.0);
            float centerDist = length(uv - centerUV);
            float2 repulsion = normalize(uv - centerUV) * (u.autoCenterRepulsion / (centerDist + 0.1));
            uv += repulsion * 0.05;
        } else if (u.mouseRepulsion > 0.5) {
            float2 mousePosUV = (u.mouse * u.resolution.xy - focalPx) / u.resolution.y;
            float mouseDist = length(uv - mousePosUV);
            float2 repulsion = normalize(uv - mousePosUV) * (u.repulsionStrength / (mouseDist + 0.1));
            uv += repulsion * 0.05 * u.mouseActiveFactor;
        } else {
            float2 mouseOffset = mouseNorm * 0.1 * u.mouseActiveFactor;
            uv += mouseOffset;
        }

        float autoRotAngle = u.time * u.rotationSpeed;
        float2x2 autoRot = float2x2(
            float2(cos(autoRotAngle), -sin(autoRotAngle)),
            float2(sin(autoRotAngle), cos(autoRotAngle))
        );
        uv = autoRot * uv;

        uv = float2x2(float2(u.rotation.x, u.rotation.y), float2(-u.rotation.y, u.rotation.x)) * uv;

        float3 col = float3(0.0);
        for (float i = 0.0; i < 1.0; i += 1.0 / kGalaxyNumLayer) {
            float depth = fract(i + u.starSpeed * u.speed);
            float scale = mix(20.0 * u.density, 0.5 * u.density, depth);
            float fade = depth * smoothstep(1.0, 0.9, depth);
            col += galaxy_StarLayer(uv * scale + i * 453.32, u) * fade;
        }

        if (u.lightMode > 0.5) {
            float energy = max(max(col.r, col.g), col.b);
            float coverage = clamp(smoothstep(0.0, 0.42, energy) * 0.92, 0.0, 0.92);
            float3 ink = clamp(col * 0.48, 0.0, 0.82);
            return float4(mix(float3(1.0), ink, coverage), 1.0);
        }
        if (u.transparent > 0.5) {
            float alpha = length(col);
            alpha = smoothstep(0.0, 0.3, alpha);
            alpha = min(alpha, 1.0);
            return float4(col, alpha);
        }
        return float4(col, 1.0);
    }

    // -------------------------------------------------------------------------
    // Liquid Chrome (React Bits LiquidChrome.tsx)
    // -------------------------------------------------------------------------

    struct LiquidChromeUniforms {
        float3 resolution;
        float time;
        float3 baseColor;
        float _pad0;
        float amplitude;
        float frequencyX;
        float frequencyY;
        float _pad1;
        float2 mouse;
        float _pad2;
    };

    inline float4 lc_renderImage(
        float2 uvCoord,
        constant LiquidChromeUniforms &u
    ) {
        float2 fragCoord = uvCoord * u.resolution.xy;
        float2 uv = (2.0 * fragCoord - u.resolution.xy) / min(u.resolution.x, u.resolution.y);

        for (float i = 1.0; i < 10.0; i += 1.0) {
            uv.x += u.amplitude / i * cos(i * u.frequencyX * uv.y + u.time + u.mouse.x * 3.14159);
            uv.y += u.amplitude / i * cos(i * u.frequencyY * uv.x + u.time + u.mouse.y * 3.14159);
        }

        float2 diff = (uvCoord - u.mouse);
        float dist = length(diff);
        float falloff = exp(-dist * 20.0);
        float ripple = sin(10.0 * dist - u.time * 2.0) * 0.03;
        uv += (diff / (dist + 0.0001)) * ripple * falloff;

        float3 color = u.baseColor / abs(sin(u.time - uv.y - uv.x));
        return float4(color, 1.0);
    }

    fragment float4 liquidChromeFragment(
        VertexOut in [[stage_in]],
        constant LiquidChromeUniforms &u [[buffer(0)]]
    ) {
        float4 col = float4(0.0);
        int samples = 0;
        float invMin = 1.0 / min(u.resolution.x, u.resolution.y);
        for (int i = -1; i <= 1; ++i) {
            for (int j = -1; j <= 1; ++j) {
                float2 offset = float2(float(i), float(j)) * invMin;
                col += lc_renderImage(in.uv + offset, u);
                samples += 1;
            }
        }
        return col / float(samples);
    }

    // -------------------------------------------------------------------------
    // Pixel Snow (React Bits PixelSnow.tsx)
    // -------------------------------------------------------------------------

    struct PixelSnowUniforms {
        float2 resolution;
        float time;
        float flakeSize;
        float minFlakeSize;
        float pixelResolution;
        float speed;
        float depthFade;
        float farPlane;
        float3 color;
        float _pad0;
        float brightness;
        float gamma;
        float density;
        float variant;
        float direction;
        float _pad1;
    };

    constant float kPixelSnowPIOver6 = 0.5235988;
    constant float kPixelSnowPIOver3 = 1.0471976;
    constant uint kPixelSnowM1 = 1597334677U;
    constant uint kPixelSnowM2 = 3812015801U;
    constant uint kPixelSnowM3 = 3299493293U;
    constant float kPixelSnowF0 = 2.3283064e-10;
    constant float3 kPixelSnowCamK = float3(0.57735027, 0.57735027, 0.57735027);
    constant float3 kPixelSnowCamI = float3(0.70710678, 0.0, -0.70710678);
    constant float3 kPixelSnowCamJ = float3(-0.40824829, 0.81649658, -0.40824829);
    constant float2 kPixelSnowB1d = float2(0.574, 0.819);

    inline uint ps_hash(uint n) {
        return n * (n ^ (n >> 15));
    }

    inline uint ps_coord3(int3 p) {
        uint3 up = uint3(p);
        return up.x * kPixelSnowM1 ^ up.y * kPixelSnowM2 ^ up.z * kPixelSnowM3;
    }

    inline float3 ps_hash3(uint n) {
        uint3 hashed = ps_hash(n) * uint3(1U, 511U, 262143U);
        return float3(hashed) * kPixelSnowF0;
    }

    inline float ps_snowflakeDist(float2 p) {
        float r = length(p);
        float a = atan2(p.y, p.x);
        a = abs(fmod(a + kPixelSnowPIOver6, kPixelSnowPIOver3) - kPixelSnowPIOver6);
        float2 q = r * float2(cos(a), sin(a));
        float dMain = max(abs(q.y), max(-q.x, q.x - 1.0));
        float b1t = clamp(dot(q - float2(0.4, 0.0), kPixelSnowB1d), 0.0, 0.4);
        float dB1 = length(q - float2(0.4, 0.0) - b1t * kPixelSnowB1d);
        float b2t = clamp(dot(q - float2(0.7, 0.0), kPixelSnowB1d), 0.0, 0.25);
        float dB2 = length(q - float2(0.7, 0.0) - b2t * kPixelSnowB1d);
        return min(dMain, min(dB1, dB2)) * 10.0;
    }

    fragment float4 pixelSnowFragment(
        VertexOut in [[stage_in]],
        constant PixelSnowUniforms &u [[buffer(0)]]
    ) {
        float invPixelRes = 1.0 / u.pixelResolution;
        float pixelSize = max(1.0, floor(0.5 + u.resolution.x * invPixelRes));
        float invPixelSize = 1.0 / pixelSize;

        float2 fragCoord = floor(in.position.xy * invPixelSize);
        float2 res = u.resolution * invPixelSize;
        float invResX = 1.0 / res.x;

        float3 ray = normalize(float3((fragCoord - res * 0.5) * invResX, 1.0));
        ray = ray.x * kPixelSnowCamI + ray.y * kPixelSnowCamJ + ray.z * kPixelSnowCamK;

        float timeSpeed = u.time * u.speed;
        float windX = cos(u.direction) * 0.4;
        float windY = sin(u.direction) * 0.4;
        float3 camPos = (windX * kPixelSnowCamI + windY * kPixelSnowCamJ + 0.1 * kPixelSnowCamK) * timeSpeed;
        float3 pos = camPos;

        float3 absRay = max(abs(ray), float3(0.001));
        float3 strides = 1.0 / absRay;
        float3 raySign = step(ray, float3(0.0));
        float3 phase = fract(pos) * strides;
        phase = mix(strides - phase, phase, raySign);

        float rayDotCamK = dot(ray, kPixelSnowCamK);
        float invRayDotCamK = 1.0 / rayDotCamK;
        float invDepthFade = 1.0 / u.depthFade;
        float halfInvResX = 0.5 * invResX;
        float3 timeAnim = timeSpeed * 0.1 * float3(7.0, 8.0, 5.0);

        float t = 0.0;
        for (int iter = 0; iter < 128; ++iter) {
            if (t >= u.farPlane) break;

            float3 fpos = floor(pos);
            uint cellCoord = ps_coord3(int3(fpos));
            float cellHash = ps_hash3(cellCoord).x;

            if (cellHash < u.density) {
                float3 h = ps_hash3(cellCoord);

                float3 sinArg1 = fpos.yzx * 0.073;
                float3 sinArg2 = fpos.zxy * 0.27;
                float3 flakePos = 0.5 - 0.5 * cos(4.0 * sin(sinArg1) + 4.0 * sin(sinArg2) + 2.0 * h + timeAnim);
                flakePos = flakePos * 0.8 + 0.1 + fpos;

                float toIntersection = dot(flakePos - pos, kPixelSnowCamK) * invRayDotCamK;

                if (toIntersection > 0.0) {
                    float3 testPos = pos + ray * toIntersection - flakePos;
                    float testX = dot(testPos, kPixelSnowCamI);
                    float testY = dot(testPos, kPixelSnowCamJ);
                    float2 testUV = abs(float2(testX, testY));

                    float depth = dot(flakePos - camPos, kPixelSnowCamK);
                    float flakeSize = max(u.flakeSize, u.minFlakeSize * depth * halfInvResX);

                    float dist;
                    if (u.variant < 0.5) {
                        dist = max(testUV.x, testUV.y);
                    } else if (u.variant < 1.5) {
                        dist = length(testUV);
                    } else {
                        float invFlakeSize = 1.0 / flakeSize;
                        dist = ps_snowflakeDist(float2(testX, testY) * invFlakeSize) * flakeSize;
                    }

                    if (dist < flakeSize) {
                        float flakeSizeRatio = u.flakeSize / flakeSize;
                        float intensity = exp2(-(t + toIntersection) * invDepthFade) *
                            min(1.0, flakeSizeRatio * flakeSizeRatio) * u.brightness;
                        return float4(u.color * pow(float3(intensity), float3(u.gamma)), 1.0);
                    }
                }
            }

            float nextStep = min(min(phase.x, phase.y), phase.z);
            float3 sel = step(phase, float3(nextStep));
            phase = phase - nextStep + strides * sel;
            t += nextStep;
            pos = mix(pos + ray * nextStep, floor(pos + ray * nextStep + 0.5), sel);
        }

        return float4(0.0);
    }

    // -------------------------------------------------------------------------
    // Evil Eye (React Bits EvilEye.tsx)
    // -------------------------------------------------------------------------

    struct EvilEyeUniforms {
        float3 resolution;
        float time;
        float pupilSize;
        float irisWidth;
        float glowIntensity;
        float intensity;
        float scale;
        float noiseScale;
        float pupilFollow;
        float flameSpeed;
        float lightMode;
        float2 mouse;
        float _pad0;
        float3 eyeColor;
        float _pad1;
        float3 bgColor;
        float _pad2;
    };

    fragment float4 evilEyeFragment(
        VertexOut in [[stage_in]],
        constant EvilEyeUniforms &u [[buffer(0)]],
        texture2d<float> noiseTexture [[texture(0)]],
        sampler noiseSampler [[sampler(0)]]
    ) {
        float2 uv = (in.position.xy * 2.0 - u.resolution.xy) / u.resolution.y;
        uv /= u.scale;
        float ft = u.time * u.flameSpeed;

        float polarRadius = length(uv) * 2.0;
        float polarAngle = (2.0 * atan2(uv.x, uv.y)) / 6.28 * 0.3;
        float2 polarUv = float2(polarRadius, polarAngle);

        float4 noiseA = noiseTexture.sample(
            noiseSampler,
            polarUv * float2(0.2, 7.0) * u.noiseScale + float2(-ft * 0.1, 0.0)
        );
        float4 noiseB = noiseTexture.sample(
            noiseSampler,
            polarUv * float2(0.3, 4.0) * u.noiseScale + float2(-ft * 0.2, 0.0)
        );
        float4 noiseC = noiseTexture.sample(
            noiseSampler,
            polarUv * float2(0.1, 5.0) * u.noiseScale + float2(-ft * 0.1, 0.0)
        );

        float distanceMask = 1.0 - length(uv);

        float innerRing = clamp(-1.0 * ((distanceMask - 0.7) / u.irisWidth), 0.0, 1.0);
        innerRing = (innerRing * distanceMask - 0.2) / 0.28;
        innerRing += noiseA.r - 0.5;
        innerRing *= 1.3;
        innerRing = clamp(innerRing, 0.0, 1.0);

        float outerRing = clamp(-1.0 * ((distanceMask - 0.5) / 0.2), 0.0, 1.0);
        outerRing = (outerRing * distanceMask - 0.1) / 0.38;
        outerRing += noiseC.r - 0.5;
        outerRing *= 1.3;
        outerRing = clamp(outerRing, 0.0, 1.0);

        innerRing += outerRing;

        float innerEye = distanceMask - 0.1 * 2.0;
        innerEye *= noiseB.r * 2.0;

        float2 pupilOffset = u.mouse * u.pupilFollow * 0.12;
        float2 pupilUv = uv - pupilOffset;
        float pupil = 1.0 - length(pupilUv * float2(9.0, 2.3));
        pupil *= u.pupilSize;
        pupil = clamp(pupil, 0.0, 1.0);
        pupil /= 0.35;

        float outerEyeGlow = 1.0 - length(uv * float2(0.5, 1.5));
        outerEyeGlow = clamp(outerEyeGlow + 0.5, 0.0, 1.0);
        outerEyeGlow += noiseC.r - 0.5;
        float outerBgGlow = outerEyeGlow;
        outerEyeGlow = pow(outerEyeGlow, 2.0);
        outerEyeGlow += distanceMask;
        outerEyeGlow *= u.glowIntensity;
        outerEyeGlow = clamp(outerEyeGlow, 0.0, 1.0);
        outerEyeGlow *= pow(1.0 - distanceMask, 2.0) * 2.5;

        outerBgGlow += distanceMask;
        outerBgGlow = pow(outerBgGlow, 0.5);
        outerBgGlow *= 0.15;

        float3 eyeEnergy = u.eyeColor * u.intensity *
            clamp(max(innerRing + innerEye, outerEyeGlow + outerBgGlow) - pupil, 0.0, 3.0);
        float3 color;
        if (u.lightMode > 0.5) {
            float3 mapped = float3(1.0) - exp(-max(eyeEnergy, float3(0.0)) * 1.3);
            float energy = clamp(max(mapped.r, max(mapped.g, mapped.b)), 0.0, 1.0);
            float3 hue = mapped / max(energy, 0.0001);
            hue = pow(clamp(hue, 0.0, 1.0), float3(1.2));
            color = mix(u.bgColor, hue, smoothstep(0.02, 0.82, energy) * 0.96);
        } else {
            color = eyeEnergy + u.bgColor;
        }

        return float4(color, 1.0);
    }

    // -------------------------------------------------------------------------
    // Aero Shards (simplified approximation — pearl diamonds, vortex, ripple)
    // -------------------------------------------------------------------------

    struct AeroShardsUniforms {
        float2 resolution;
        float time;
        float2 mouse;
        float pointerActive;
        float parallax;
        float _pad0;
    };

    inline float as_hash21(float2 p) {
        float3 p3 = fract(float3(p.xyx) * 0.1031);
        p3 += dot(p3, p3.yzx + 33.33);
        return fract((p3.x + p3.y) * p3.z);
    }

    inline float2 as_hash22(float2 p) {
        float3 p3 = fract(float3(p.xyx) * float3(0.1031, 0.1030, 0.0973));
        p3 += dot(p3, p3.yzx + 33.33);
        return fract((p3.xx + p3.yz) * p3.zy);
    }

    inline float as_diamondSDF(float2 p, float size) {
        float2 q = abs(p);
        return (q.x + q.y - size) / sqrt(2.0);
    }

    inline float3 as_iridescent(float edge, float hue, float time) {
        float3 a = float3(0.55, 0.72, 1.0);
        float3 b = float3(1.0, 0.82, 0.95);
        float3 c = float3(0.75, 1.0, 0.88);
        float t = hue + time * 0.15 + edge * 2.5;
        float3 col = mix(a, b, 0.5 + 0.5 * sin(t * 6.283));
        col = mix(col, c, 0.5 + 0.5 * cos(t * 4.1 + 1.7));
        return col * (0.35 + 0.65 * pow(edge, 0.6));
    }

    fragment float4 aeroShardsFragment(
        VertexOut in [[stage_in]],
        constant AeroShardsUniforms &u [[buffer(0)]]
    ) {
        float2 res = u.resolution;
        float2 uv = (in.position.xy / res) * 2.0 - 1.0;
        uv.x *= res.x / res.y;

        float2 pointer = (u.mouse * 2.0 - 1.0) * float2(1.0, -1.0);
        pointer.x *= res.x / res.y;
        float2 toPointer = uv - pointer * u.parallax * u.pointerActive;
        float rippleDist = length(toPointer);
        float ripple = sin(rippleDist * 18.0 - u.time * 3.5) * exp(-rippleDist * 3.5) * 0.04 * u.pointerActive;

        float3 col = float3(0.015, 0.018, 0.028);
        float aspect = res.x / res.y;

        for (int i = 0; i < 40; ++i) {
            float fi = float(i);
            float seed = as_hash21(float2(fi, fi * 1.37));
            float seed2 = as_hash21(float2(fi * 2.1, fi * 0.73));

            float angle = seed * 6.283 + u.time * (0.12 + seed2 * 0.18);
            float radius = 0.15 + seed2 * 0.55;
            float vortex = u.time * (0.25 + seed * 0.35) + fi * 0.31;
            float2 center = float2(cos(angle + vortex), sin(angle + vortex * 0.87)) * radius;
            center.x *= aspect;
            center += float2(sin(u.time * 0.2 + fi), cos(u.time * 0.17 + fi * 1.3)) * 0.06;

            float2 local = uv - center;
            float rot = vortex * 1.4 + seed * 6.283;
            float c = cos(rot);
            float s = sin(rot);
            local = float2x2(float2(c, -s), float2(s, c)) * local;

            float size = 0.018 + seed2 * 0.035;
            float d = as_diamondSDF(local + float2(ripple * (1.0 + seed)), size);
            float body = smoothstep(0.012, -0.002, d);
            float edge = smoothstep(0.018, 0.0, abs(d)) * body;

            float3 pearl = mix(float3(0.82, 0.86, 0.94), float3(0.95, 0.97, 1.0), seed);
            pearl += as_iridescent(edge, seed + seed2, u.time) * edge;

            float glow = exp(-max(d, 0.0) * 120.0) * 0.25;
            float alpha = body * (0.55 + 0.45 * seed) + glow;

            col += pearl * alpha;
        }

        col = col / (col + float3(1.0));
        col = pow(col, float3(0.92));
        return float4(col, 1.0);
    }
    """
}
