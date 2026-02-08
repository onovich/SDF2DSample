Shader "Universal/SDF_2D_Ultimate_Fixed_Final_v10"
{
    Properties
    {
        [Header(Base Settings)]
        [PerRendererData] _MainTex ("Sprite Texture", 2D) = "white" {}
        _Color ("Tint", Color) = (1,1,1,1)
        
        [Header(Shape Settings)]
        [KeywordEnum(Circle, Box, Polygon, Star)] _Shape("Shape Type", Float) = 2
        _Size("Size (Radius)", Range(0, 0.5)) = 0.3
        
        // ✨ 圆角半径：主要影响外侧尖角
        _Roundness("Corner Radius", Range(0, 0.2)) = 0.05

        [IntegerRange] _PolySides ("Polygon Sides", Range(3, 12)) = 5
        [IntegerRange] _StarPts ("Star Points", Range(3, 12)) = 5
        _StarInner ("Star Inner Radius", Range(0.1, 0.95)) = 0.4

        [Header(Fill Settings)]
        [Toggle] _UseFill("Use Fill", Float) = 1
        _FillColor("Fill Color", Color) = (1, 0, 0, 1)
        
        [Header(Stroke Settings)]
        [Toggle] _UseStroke("Use Stroke", Float) = 1
        [KeywordEnum(Center, Inner, Outer)] _StrokeAlign("Stroke Align", Float) = 2
        _StrokeColor("Stroke Color", Color) = (1, 1, 1, 1)
        _StrokeWidth("Stroke Width", Range(0, 0.2)) = 0.02
        
        [Header(Render Quality)]
        [Toggle] _FixAspect("Auto Fix Aspect Ratio", Float) = 1
        _AAStrength("Anti-Alias Strength", Range(0.5, 4.0)) = 1.0

        // --- UI Mask Support ---
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
            Name "SDF_2D_Euclidean_v10"
            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            
            #pragma multi_compile _SHAPE_CIRCLE _SHAPE_BOX _SHAPE_POLYGON _SHAPE_STAR
            #pragma multi_compile _STROKEALIGN_CENTER _STROKEALIGN_INNER _STROKEALIGN_OUTER
            #pragma shader_feature_local _FIXASPECT_ON
            #pragma shader_feature_local _USEFILL_ON
            #pragma shader_feature_local _USESTROKE_ON

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

            // ==========================================
            // 📐 SDF 数学库 (全欧几里得距离修正版)
            // ==========================================

            float sdCircle(float2 p, float r) { 
                return length(p) - r; 
            }
            
            float sdBox(float2 p, float2 b) {
                float2 d = abs(p) - b;
                return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0);
            }

            // ✨ 通用星星/多边形逻辑
            // 这是计算“点到线段距离”的精确算法，支持圆角
            float sdStarGeneric(float2 p, float r, float points, float innerRadius) {
                // 1. 扇形折叠：将空间折叠到一个切片中
                int n = int(max(3.0, round(points)));
                float an = PI / float(n);
                float en = 2.0 * PI / float(n); // 360/n
                
                // 旋转对其，使尖角朝上
                float a = atan2(p.x, p.y) + an; 
                float sector = floor(a / en);
                a -= sector * en;
                a -= an;
                p = length(p) * float2(sin(a), cos(a));
                
                // 2. 距离计算
                // 线段端点：p1是外尖角，p2是内拐点
                p.x = abs(p.x);
                float2 p1 = float2(0.0, r);
                float2 p2 = float2(sin(an), cos(an)) * innerRadius;
                
                // 计算点p到线段p1-p2的距离向量
                float2 e = p2 - p1;
                float2 w = p - p1;
                float2 d_vec = w - e * clamp(dot(w, e) / dot(e, e), 0.0, 1.0);
                float d_seg = length(d_vec);
                
                // 3. 符号判定 (使用叉积判断内外)
                float s = w.x * e.y - w.y * e.x;
                return d_seg * -sign(s); 
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
                
                // 🛠️ 预处理：为了防止圆角导致图形膨胀，我们先缩小基础图形
                // 限制 roundness 不超过 size，否则图形会消失
                float r_corner = min(_Roundness, _Size - 0.001);
                float size_geo = _Size - r_corner; 

                #if defined(_SHAPE_CIRCLE)
                    // 圆形不受圆角参数影响 (或者说它已经是圆角了)
                    d = sdCircle(uv, size_geo);
                    
                #elif defined(_SHAPE_BOX)
                    d = sdBox(uv, float2(size_geo, size_geo));
                    
                #elif defined(_SHAPE_POLYGON)
                    // ✨ 核心修复：
                    // 正多边形 = 内半径为 r*cos(PI/n) 的星星
                    // 这样我们可以复用基于线段的精确 SDF，从而支持完美的圆角
                    float an = PI / max(3.0, round(_PolySides));
                    float polyInner = size_geo * cos(an);
                    d = sdStarGeneric(uv, size_geo, _PolySides, polyInner);
                    
                #elif defined(_SHAPE_STAR)
                    // 星星计算
                    // 注意：Roundness 只能圆润外面的尖角，内部的凹角在数学上无法简单通过减法圆润
                    d = sdStarGeneric(uv, size_geo, _StarPts, size_geo * _StarInner);
                #endif

                // ✨ 应用圆角
                // 减去半径 = 向外扩张等值线 = 尖角变圆
                d -= r_corner;

                half4 finalColor = half4(0,0,0,0);
                // 自动计算抗锯齿宽度
                float aa = max(fwidth(d), 0.0001) * _AAStrength;

                // --- 填充渲染 ---
                #if _USEFILL_ON
                    float fillAlpha = 1.0 - smoothstep(-aa, aa, d);
                    finalColor = _FillColor * fillAlpha;
                #endif

                // --- 描边渲染 ---
                #if _USESTROKE_ON
                    float d_stroke = d;
                    float halfWidth = _StrokeWidth * 0.5;
                    
                    // 对齐修正：改变 stroke 计算的基准线
                    #if defined(_STROKEALIGN_INNER)
                         d_stroke += halfWidth; // 描边完全在内部
                    #elif defined(_STROKEALIGN_OUTER)
                         d_stroke -= halfWidth; // 描边完全在外部
                    #endif
                    
                    // 计算描边（绝对距离 - 半宽）
                    float distToStroke = abs(d_stroke) - halfWidth;
                    float strokeAlpha = 1.0 - smoothstep(-aa, aa, distToStroke);
                    
                    // 混合颜色
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