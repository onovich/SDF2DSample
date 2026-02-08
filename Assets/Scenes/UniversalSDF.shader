Shader "Universal/SDF_2D_Ultimate_Fixed_Final_v11"
{
    Properties
    {
        [Header(Base Settings)]
        [PerRendererData] _MainTex ("Sprite Texture", 2D) = "white" {}
        _Color ("Tint", Color) = (1,1,1,1)
        
        [Header(Shape Settings)]
        [KeywordEnum(Circle, Box, Polygon, Star)] _Shape("Shape Type", Float) = 3
        _Size("Size (Radius)", Range(0, 0.5)) = 0.3
        
        // ✨ 新增：强制尖角模式
        // 勾选此项后，_Roundness 将失效，但星星的内角会变得像针一样尖
        [Toggle] _UseMiter("Force Sharp Corners (Miter)", Float) = 0
        
        // 此参数仅在 _UseMiter 关闭时生效
        _Roundness("Corner Radius (Smooth Mode)", Range(0, 0.2)) = 0.0

        [IntegerRange] _PolySides ("Polygon Sides", Range(3, 12)) = 5
        [IntegerRange] _StarPts ("Star Points", Range(3, 12)) = 8
        _StarInner ("Star Inner Radius", Range(0.1, 0.95)) = 0.5

        [Header(Fill Settings)]
        [Toggle] _UseFill("Use Fill", Float) = 1
        _FillColor("Fill Color", Color) = (1, 0, 0, 1)
        
        [Header(Stroke Settings)]
        [Toggle] _UseStroke("Use Stroke", Float) = 1
        [KeywordEnum(Center, Inner, Outer)] _StrokeAlign("Stroke Align", Float) = 1
        _StrokeColor("Stroke Color", Color) = (1, 1, 1, 1)
        _StrokeWidth("Stroke Width", Range(0, 0.2)) = 0.05
        
        [Header(Render Quality)]
        [Toggle] _FixAspect("Auto Fix Aspect Ratio", Float) = 1
        _AAStrength("Anti-Alias Strength", Range(0.5, 4.0)) = 1.0

        // Mask Support
        [HideInInspector] _StencilComp ("Stencil Comparison", Float) = 8
        [HideInInspector] _Stencil ("Stencil ID", Float) = 0
        [HideInInspector] _StencilOp ("Stencil Operation", Float) = 0
        [HideInInspector] _StencilWriteMask ("Stencil Write Mask", Float) = 255
        [HideInInspector] _StencilReadMask ("Stencil Read Mask", Float) = 255
        [HideInInspector] _ColorMask ("Color Mask", Float) = 15
    }

    SubShader
    {
        Tags
        { 
            "Queue"="Transparent" 
            "IgnoreProjector"="True" 
            "RenderType"="Transparent" 
            "PreviewType"="Plane"
            "CanUseSpriteAtlas"="True"
            "RenderPipeline" = "UniversalPipeline"
        }

        Stencil { Ref [_Stencil] Comp [_StencilComp] Pass [_StencilOp] ReadMask [_StencilReadMask] WriteMask [_StencilWriteMask] }
        Cull Off Lighting Off ZWrite Off ZTest [unity_GUIZTestMode] Blend SrcAlpha OneMinusSrcAlpha ColorMask [_ColorMask]

        Pass
        {
            Name "SDF_2D_Sharp_v11"
            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            
            #pragma multi_compile _SHAPE_CIRCLE _SHAPE_BOX _SHAPE_POLYGON _SHAPE_STAR
            #pragma multi_compile _STROKEALIGN_CENTER _STROKEALIGN_INNER _STROKEALIGN_OUTER
            #pragma shader_feature_local _FIXASPECT_ON
            #pragma shader_feature_local _USEFILL_ON
            #pragma shader_feature_local _USESTROKE_ON
            #pragma shader_feature_local _USEMITER_ON 

            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"

            struct Attributes
            {
                float4 positionOS : POSITION;
                float4 color : COLOR;
                float2 uv : TEXCOORD0;
            };

            struct Varyings
            {
                float4 positionCS : SV_POSITION;
                float4 color : COLOR;
                float2 uv : TEXCOORD0;
            };

            CBUFFER_START(UnityPerMaterial)
                float4 _Color;
                float4 _FillColor;
                float4 _StrokeColor;
                float _Size;
                float _StrokeWidth;
                float _AAStrength;
                float _StarInner;
                float _PolySides;
                float _StarPts;
                float _Roundness;
            CBUFFER_END
            
            #define PI 3.14159265359

            Varyings vert(Attributes input)
            {
                Varyings output;
                output.positionCS = TransformObjectToHClip(input.positionOS.xyz);
                output.uv = input.uv;
                output.color = input.color * _Color; 
                return output;
            }

            // SDF Functions
            float sdCircle(float2 p, float r) { 
                return length(p) - r; 
            }
            
            float sdBox(float2 p, float2 b) {
                float2 d = abs(p) - b;
                return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0);
            }

            // ✨ 通用星星/多边形逻辑 (支持 Miter/Sharp 模式)
            float sdStarGeneric(float2 p, float r, float points, float innerRadius) {
                // 1. 扇形折叠 (坐标系旋转对齐)
                int n = int(max(3.0, round(points)));
                float an = PI / float(n);
                float en = 2.0 * PI / float(n);
                
                float a = atan2(p.x, p.y) + an; 
                float sector = floor(a / en);
                a -= sector * en;
                a -= an;
                p = length(p) * float2(sin(a), cos(a));
                
                // 2. 线段参数
                p.x = abs(p.x);
                float2 p1 = float2(0.0, r);
                float2 p2 = float2(sin(an), cos(an)) * innerRadius;
                
                float2 e = p2 - p1;
                float2 w = p - p1;

                // 3. 计算距离
                #if _USEMITER_ON
                    // ✨ 尖角模式 (Miter Mode)
                    // 利用叉积计算点到无限直线的垂直距离 (Height = Area / Base)
                    // 这种方式不会产生圆角，等值线是平行的直线
                    float val = w.x * e.y - w.y * e.x;
                    float dist = val / length(e);
                    
                    // 符号修正：Star SDF 约定内部为负。
                    // 按照叉积方向，内部可能为正，取反即可。
                    return -dist; 
                #else
                    // ✨ 平滑模式 (Euclidean Mode - 默认)
                    // 计算点到线段的欧几里得距离
                    // 这种方式在凹角处会产生圆弧
                    float2 d_vec = w - e * clamp(dot(w, e) / dot(e, e), 0.0, 1.0);
                    float d_seg = length(d_vec);
                    float s = w.x * e.y - w.y * e.x;
                    return d_seg * -sign(s);
                #endif
            }

            half4 frag(Varyings input) : SV_Target
            {
                float2 uv = input.uv * 2.0 - 1.0;
                #if _FIXASPECT_ON
                    float2 derivatives = fwidth(input.uv);
                    if (abs(derivatives.y) > 1e-5) {
                         float aspect = derivatives.x / derivatives.y;
                         if (aspect > 1.0) uv.x *= aspect;
                         else uv.y /= aspect;
                    }
                #endif

                float d = 0;
                
                // 逻辑分支：如果开启了 Miter 模式，Roundness 必须忽略 (因为 Miter 不支持圆角)
                // 否则使用标准的缩小逻辑来支持 Roundness
                #if _USEMITER_ON
                    float size_geo = _Size;
                #else
                    float r_corner = min(_Roundness, _Size - 0.001);
                    float size_geo = _Size - r_corner;
                #endif

                #if defined(_SHAPE_CIRCLE)
                    d = sdCircle(uv, size_geo); // 圆形不受 Miter 影响
                #elif defined(_SHAPE_BOX)
                    // Box 在 Miter 模式下其实就是 size_geo，但为了统一代码结构保持不变
                    // Box 的 SDF 本身就是 Miter 性质的 (直角距离)，所以这里区别不大
                    d = sdBox(uv, float2(size_geo, size_geo));
                #elif defined(_SHAPE_POLYGON)
                    float an = PI / max(3.0, round(_PolySides));
                    float polyInner = size_geo * cos(an);
                    d = sdStarGeneric(uv, size_geo, _PolySides, polyInner);
                #elif defined(_SHAPE_STAR)
                    d = sdStarGeneric(uv, size_geo, _StarPts, size_geo * _StarInner);
                #endif

                // 只有在非 Miter 模式下，才应用圆角平滑
                #if !_USEMITER_ON
                    d -= r_corner;
                #endif

                half4 finalColor = half4(0,0,0,0);
                float aa = max(fwidth(d), 0.0001) * _AAStrength;

                #if _USEFILL_ON
                    float fillAlpha = 1.0 - smoothstep(-aa, aa, d);
                    finalColor = _FillColor * fillAlpha;
                #endif

                #if _USESTROKE_ON
                    float d_stroke = d;
                    float halfWidth = _StrokeWidth * 0.5;
                    
                    #if defined(_STROKEALIGN_INNER)
                         d_stroke += halfWidth;
                    #elif defined(_STROKEALIGN_OUTER)
                         d_stroke -= halfWidth;
                    #endif
                    
                    float distToStroke = abs(d_stroke) - halfWidth;
                    float strokeAlpha = 1.0 - smoothstep(-aa, aa, distToStroke);
                    
                    finalColor.rgb = lerp(finalColor.rgb, _StrokeColor.rgb, strokeAlpha);
                    finalColor.a = max(finalColor.a, strokeAlpha * _StrokeColor.a);
                #endif

                finalColor *= input.color;
                return finalColor;
            }
            ENDHLSL
        }
    }
}