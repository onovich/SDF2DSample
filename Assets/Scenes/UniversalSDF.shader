Shader "Universal/SDF_2D_Ultimate"
{
    Properties
    {
        [Header(Base Settings)]
        [PerRendererData] _MainTex ("Sprite Texture", 2D) = "white" {}
        _Color ("Tint", Color) = (1,1,1,1)
        
        [Header(Shape Settings)]
        [KeywordEnum(Circle, Box, Hexagon, Star)] _Shape("Shape Type", Float) = 0
        _Size("Size", Range(0, 0.5)) = 0.4
        
        [Header(Appearance)]
        _FillColor("Fill Color", Color) = (1, 0, 0, 1)
        [Toggle] _UseFill("Use Fill", Float) = 1
        
        [Toggle] _UseStroke("Use Stroke", Float) = 1
        _StrokeColor("Stroke Color", Color) = (1, 1, 1, 1)
        _StrokeWidth("Stroke Width", Range(0, 0.2)) = 0.02
        
        [Header(Tools)]
        [Toggle] _FixAspect("Fix Aspect Ratio", Float) = 1
        _Smoothness("Edge Smoothness", Range(0.001, 0.1)) = 0.005

        // --- UI Mask Support (Required for Stencil/Masking to work) ---
        _StencilComp ("Stencil Comparison", Float) = 8
        _Stencil ("Stencil ID", Float) = 0
        _StencilOp ("Stencil Operation", Float) = 0
        _StencilWriteMask ("Stencil Write Mask", Float) = 255
        _StencilReadMask ("Stencil Read Mask", Float) = 255
        _ColorMask ("Color Mask", Float) = 15
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

        // UI Mask Support
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
            Name "SDF_2D_Pass"
            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #pragma multi_compile _SHAPE_CIRCLE _SHAPE_BOX _SHAPE_HEXAGON _SHAPE_STAR
            // 编译 Shader 变体以支持开关
            #pragma shader_feature_local _FIXASPECT_ON
            #pragma shader_feature_local _USEFILL_ON
            #pragma shader_feature_local _USESTROKE_ON

            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            
            // 引入 UI 相关的辅助函数（虽然我们手写了大部分，但保持兼容性）
            // 如果你的项目报错找不到这个，可以注释掉，通常 URP Core 已经够用了
            // #include "Packages/com.unity.render-pipelines.core/ShaderLibrary/Common.hlsl"

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
                float _Smoothness;
            CBUFFER_END

            Varyings vert(Attributes input)
            {
                Varyings output;
                output.positionCS = TransformObjectToHClip(input.positionOS.xyz);
                output.uv = input.uv;
                // 传递顶点颜色 (SpriteRenderer 和 UI Image 的颜色属性)
                output.color = input.color * _Color; 
                return output;
            }

            // --- SDF Formulas ---
            float sdCircle(float2 p, float r) { return length(p) - r; }
            
            float sdBox(float2 p, float2 b) {
                float2 d = abs(p) - b;
                return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0);
            }

            float sdHexagon(float2 p, float r) {
                const float3 k = float3(-0.866025404, 0.5, 0.577350269);
                p = abs(p);
                p -= 2.0 * min(dot(k.xy, p), 0.0) * k.xy;
                p -= float2(clamp(p.x, -k.z * r, k.z * r), r);
                return length(p) * sign(p.y);
            }

            float sdStar5(float2 p, float r, float rf) {
                const float2 k1 = float2(0.809016994375, -0.587785252292);
                const float2 k2 = float2(-k1.x, k1.y);
                p.x = abs(p.x);
                p -= 2.0 * max(dot(k1, p), 0.0) * k1;
                p -= 2.0 * max(dot(k2, p), 0.0) * k2;
                p.x = abs(p.x);
                p.y -= r;
                float2 ba = rf * float2(-k1.y, k1.x) - float2(0, 1);
                float h = clamp(dot(p, ba) / dot(ba, ba), 0.0, r);
                return length(p - ba * h) * sign(p.y * ba.x - p.x * ba.y);
            }

            half4 frag(Varyings input) : SV_Target
            {
                // 1. 坐标归一化：中心点 (0,0)
                float2 uv = input.uv * 2.0 - 1.0;

                // 2. 纵横比自动修正 (Auto Aspect Ratio Fix)
                #if _FIXASPECT_ON
                    // fwidth = abs(ddx) + abs(ddy)
                    // 通过计算 UV 在屏幕上的变化率，我们可以知道纹理被拉伸了多少
                    float2 derivatives = fwidth(input.uv);
                    // 如果 x 方向变化比 y 快，说明 x 被压扁了或者 y 被拉长了
                    // 我们修正 uv 坐标来抵消这种拉伸
                    if (derivatives.x > 0 && derivatives.y > 0)
                    {
                        float aspect = derivatives.x / derivatives.y;
                        if (aspect > 1.0)
                            uv.x *= aspect; // 修正宽图
                        else
                            uv.y /= aspect; // 修正高图 (注意除法)
                    }
                #endif

                float d = 0;

                // 3. 形状计算
                #if defined(_SHAPE_CIRCLE)
                    d = sdCircle(uv, _Size);
                #elif defined(_SHAPE_BOX)
                    d = sdBox(uv, float2(_Size, _Size));
                #elif defined(_SHAPE_HEXAGON)
                    d = sdHexagon(uv, _Size);
                #elif defined(_SHAPE_STAR)
                    d = sdStar5(uv, _Size, _Size * 0.5);
                #endif

                half4 finalColor = half4(0,0,0,0);

                // 4. 渲染逻辑 (Fill & Stroke)
                
                // alpha 必须根据 fwidth 动态调整，或者使用用户输入的 _Smoothness
                // 这里使用用户输入的 smoothness 获得更艺术的控制，
                // 如果想要绝对清晰，可以用 fwidth(d) 替换 _Smoothness
                float aa = _Smoothness;

                // --- 填充 (Fill) ---
                #if _USEFILL_ON
                    // SDF < 0 表示在内部
                    float fillAlpha = 1.0 - smoothstep(0.0 - aa, 0.0 + aa, d);
                    // 叠加颜色
                    finalColor = _FillColor * fillAlpha;
                #endif

                // --- 描边 (Stroke) ---
                #if _USESTROKE_ON
                    // 描边的 SDF 逻辑：取绝对值 abs(d) - strokeWidth
                    // 如果 d = 0 (边缘)，abs(d) = 0。描边应该以此为中心。
                    // 但是通常描边是向外还是向内？
                    // SDF 的描边通常是居中的。如果想要内描边或外描边，可以对 d 进行偏移。
                    // 这里我们实现 居中描边 (Centered Stroke)
                    
                    float strokeDist = abs(d) - _StrokeWidth * 0.5;
                    float strokeAlpha = 1.0 - smoothstep(0.0 - aa, 0.0 + aa, strokeDist);
                    
                    // 混合逻辑：如果这像素是描边，就显示描边色
                    // 简单的 alpha 混合公式：Result = Stroke * StrokeA + Fill * (1 - StrokeA)
                    finalColor = lerp(finalColor, _StrokeColor, strokeAlpha);
                    
                    // 修正最终 Alpha：如果原本没填充，现在只显示描边
                    finalColor.a = max(finalColor.a, strokeAlpha * _StrokeColor.a);
                #endif

                // 5. 应用顶点颜色 (Tint)
                // 这一步很重要，这让 Image 组件的 Color 属性和 SpriteRenderer 的 Color 属性能生效
                finalColor *= input.color;

                // 6. 硬切 (Clip) - 优化性能，如果完全透明则丢弃
                // if (finalColor.a < 0.001) discard; 
                // 注意：在移动端 discard 可能会影响性能，但在 UI 中通常无所谓

                return finalColor;
            }
            ENDHLSL
        }
    }
}