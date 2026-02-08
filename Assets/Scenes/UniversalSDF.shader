Shader "Universal/SDF_2D_Ultimate_Fixed_Final_v8"
{
    Properties
    {
        [Header(Base Settings)]
        [PerRendererData] _MainTex ("Sprite Texture", 2D) = "white" {}
        _Color ("Tint", Color) = (1,1,1,1)
        
        [Header(Shape Settings)]
        // 默认选 Star 验证修复
        [KeywordEnum(Circle, Box, Polygon, Star)] _Shape("Shape Type", Float) = 3
        _Size("Size (Radius)", Range(0, 0.5)) = 0.3
        
        [IntegerRange] _PolySides ("Polygon Sides", Range(3, 12)) = 6
        [IntegerRange] _StarPts ("Star Points", Range(3, 12)) = 5
        _StarInner ("Star Inner Radius", Range(0.1, 0.95)) = 0.4

        [Header(Fill Settings)]
        [Toggle] _UseFill("Use Fill", Float) = 1
        _FillColor("Fill Color", Color) = (1, 0, 0, 1)
        
        [Header(Stroke Settings)]
        [Toggle] _UseStroke("Use Stroke", Float) = 1
        [KeywordEnum(Center, Inner, Outer)] _StrokeAlign("Stroke Align", Float) = 0
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

        Stencil
        {
            Ref [_Stencil]
            Comp [_StencilComp]
            Pass [_StencilOp]
            ReadMask [_StencilReadMask]
            WriteMask [_StencilWriteMask]
        }

        Cull Off
        Lighting Off
        ZWrite Off
        ZTest [unity_GUIZTestMode]
        Blend SrcAlpha OneMinusSrcAlpha
        ColorMask [_ColorMask]

        Pass
        {
            Name "SDF_2D_Corrected_v8"
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
            // 📐 SDF 核心数学库
            // ==========================================

            float sdCircle(float2 p, float r) { 
                return length(p) - r; 
            }
            
            float sdBox(float2 p, float2 b) {
                float2 d = abs(p) - b;
                return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0);
            }

            // ✅ 多边形 (保持上次正确状态，完全未改动)
            float sdPolygon(float2 p, float r, float sides) {
                int n = int(max(3.0, round(sides)));
                float an = PI / float(n);
                float angle = atan2(p.x, p.y) + PI; 
                float bn = 2.0 * an;
                float sector = floor(angle / bn + 0.5);
                angle -= sector * bn;
                return length(p) * cos(angle) - r * cos(an);
            }

            // ✅ 多角星 (仅修正符号计算)
            float sdStar(float2 p, float r, float points, float innerRatio) {
                int n = int(max(3.0, round(points)));
                float an = PI / float(n);
                float en = 2.0 * PI / float(n);
                
                // 1. 扇形折叠 (不变)
                float a = atan2(p.x, p.y) + an; 
                float sector = floor(a / en);
                a -= sector * en;
                a -= an;
                p = length(p) * float2(sin(a), cos(a));
                
                // 2. 线段距离 (不变)
                p.x = abs(p.x);
                float r2 = r * innerRatio;
                float2 p1 = float2(0.0, r);
                float2 p2 = float2(sin(an), cos(an)) * r2;
                float2 e = p2 - p1;
                float2 w = p - p1; // w 是点 p 相对于 p1 的偏移量
                float d_seg = length(w - e * clamp(dot(w, e) / dot(e, e), 0.0, 1.0));
                
                // 3. 符号判定 (✨修正点✨)
                // 错误代码: s = p.x * e.y - p.y * e.x; (这是相对于原点的叉积)
                // 正确代码: s = w.x * e.y - w.y * e.x; (这是相对于线段起点 p1 的叉积)
                // w 已经在上面计算过了 (w = p - p1)
                float s = w.x * e.y - w.y * e.x;
                
                // 原点处 s > 0 (正数)，代表内部
                // SDF 约定：内部为负，外部为正
                // 所以我们需要取反: -sign(s)
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

                #if defined(_SHAPE_CIRCLE)
                    d = sdCircle(uv, _Size);
                #elif defined(_SHAPE_BOX)
                    d = sdBox(uv, float2(_Size, _Size));
                #elif defined(_SHAPE_POLYGON)
                    d = sdPolygon(uv, _Size, _PolySides);
                #elif defined(_SHAPE_STAR)
                    d = sdStar(uv, _Size, _StarPts, _StarInner);
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