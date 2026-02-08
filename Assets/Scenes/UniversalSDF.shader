Shader "Universal/SDF_2D_Ultimate_Fixed_Final_v6"
{
    Properties
    {
        [Header(Base Settings)]
        [PerRendererData] _MainTex ("Sprite Texture", 2D) = "white" {}
        _Color ("Tint", Color) = (1,1,1,1)
        
        [Header(Shape Settings)]
        // 默认选 Star 方便验证
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
            Name "SDF_2D_Corrected_v6"
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
            // 📐 SDF 核心数学库 (标准实现)
            // ==========================================

            float sdCircle(float2 p, float r) { 
                return length(p) - r; 
            }
            
            float sdBox(float2 p, float2 b) {
                float2 d = abs(p) - b;
                return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0);
            }

            // ✅ 真正的多边形公式 (Based on Inigo Quilez)
            // 1. 获取角度
            // 2. 将角度归一化到 [-PI/N, PI/N] 的区间 (Sector)
            // 3. 利用极坐标公式计算距离
            float sdPolygon(float2 p, float r, float sides) {
                // 强制转整
                int n = int(max(3.0, round(sides)));
                
                // 扇形半角
                float an = PI / float(n);
                float he = r * tan(an); // 这一步其实不需要，如果是外接圆定义的话
                
                // 1. 坐标转换
                // atan2(y, x) 0度在右。 atan2(x, y) 0度在上(Y轴)
                // 我们统一用 atan2(x, -y) 让底部平齐，或者 atan2(x, y) 让顶部是尖角
                // 这里使用 atan2(p.x, p.y) + PI，让 Y 轴正方向为 0 度
                float angle = atan2(p.x, p.y);
                float bn = 2.0 * an; // 扇形全角
                
                // 2. 角度折叠 (Folding)
                // 这一步利用 fmod (HLSL) 或 floor 来循环角度
                // 我们把 angle 偏移 bn/2 使得 0 在扇区中心
                // HLSL 的 fmod 对负数处理不同，所以我们用手动 floor
                float sector = floor(angle / bn + 0.5);
                angle -= sector * bn;
                
                // 3. 计算距离
                // 现在的 angle 在 [-an, an] 之间
                // 图形退化为一个等腰三角形，我们需要计算点到底边的距离
                // p 的长度为 length(p)
                // 投影到边心距方向的长度 = length(p) * cos(angle)
                // 边心距 (apothem) = r * cos(an)
                
                return length(p) * cos(angle) - r * cos(an);
            }

            // ✅ 真正的多角星公式 (Based on Inigo Quilez)
            // 它是 N 个连接在一起的线段。
            // 这里的逻辑是：折叠空间，然后计算点到线段的距离。
            float sdStar(float2 p, float r, float points, float innerRatio) {
                // 强制转整
                int n = int(max(3.0, round(points)));
                
                // 1. 扇形折叠
                // Inigo Quilez 的巧妙算法：不依赖 atan2 的接缝
                float an = 3.141593 / float(n);
                float en = 6.283186 / float(n);
                
                // 预计算坐标旋转向量
                float2 acs = float2(cos(an), sin(an));
                float2 ecs = float2(cos(en), sin(en)); 
                
                // --- 核心折叠逻辑 (无需 atan2) ---
                // 这里的 mod 逻辑是为了把角度归一化
                float bn = atan2(p.x, p.y);
                bn = bn % en; // HLSL 取模
                // 修正 HLSL 负数取模问题:
                if (bn < 0) bn += en;
                
                // 这是一个更通用的折叠：
                // 算出扇区 ID
                float a = atan2(p.x, p.y) + an; // +an 是为了让尖端对齐Y轴
                float sector = floor(a / en);
                a -= sector * en;
                a -= an; // 恢复中心
                
                // 刚体旋转 p (二维旋转公式)
                float ca = cos(a);
                float sa = sin(a);
                // 这里的 p 变成了局部坐标 cs
                float2 cs = float2(p.x * ca - p.y * sa, p.x * sa + p.y * ca); 
                // 由于我们只需要算半边距离，对称一下 X
                // 注意：这里旋转后，尖端在 Y 轴上
                // 我们希望利用对称性，把 X < 0 的部分翻折过来
                // 但上面的旋转已经把 p 放到标准扇区了
                
                // 下面改用更直接的线段 SDF 方法，避免旋转带来的迷惑
                // ------------------------------------------------
                
                // 重置 p (使用前面 sdPolygon 的稳定折叠逻辑)
                float ang = atan2(p.x, p.y);
                float sect = floor(ang/en + 0.5);
                ang -= sect * en;
                
                // 极坐标重构 p (这是最安全的刚体变换)
                // 在局部空间，角平分线是 Y 轴 (0度)
                p = length(p) * float2(sin(ang), cos(ang));
                
                // 2. 线段定义
                // 顶点 A: (0, r)
                // 凹点 B: (r*m*sin(an), r*m*cos(an))
                // 注意：凹点在角度 an 处
                
                p.x = abs(p.x); // 对称
                
                float r2 = r * innerRatio;
                float2 p1 = float2(0.0, r);
                float2 p2 = float2(sin(an), cos(an)) * r2;
                
                // 3. 点到线段距离
                float2 e = p2 - p1;
                float2 w = p - p1;
                
                // 投影并 clamp
                float d_seg = length(w - e * clamp(dot(w, e) / dot(e, e), 0.0, 1.0));
                
                // 4. 符号计算 (Sign)
                // 使用叉乘判断内外
                // e 是向下指的，p 在 e 的右侧 (Cross Z < 0) 为内部？
                // 验证：原点 (0,0) -> w=(0,-r) -> cross > 0
                // 外部是正，内部是负。
                // 修正：sdStar 必须用 sign(cross) * d
                float s = p.x * e.y - p.y * e.x;
                
                return d_seg * sign(s);
            }

            half4 frag(Varyings input) : SV_Target
            {
                // 1. 坐标修正
                float2 uv = input.uv * 2.0 - 1.0;

                // 2. 纵横比修正
                #if _FIXASPECT_ON
                    float2 derivatives = fwidth(input.uv);
                    if (abs(derivatives.y) > 1e-5) {
                         float aspect = derivatives.x / derivatives.y;
                         if (aspect > 1.0) uv.x *= aspect;
                         else uv.y /= aspect;
                    }
                #endif

                float d = 0;

                // 3. 形状计算
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
                
                // 4. 抗锯齿
                // fwidth 计算屏幕像素对应的 SDF 距离
                float aa = fwidth(d) * _AAStrength;
                aa = max(aa, 0.0001); // 安全下限

                // --- 填充 (Fill) ---
                #if _USEFILL_ON
                    // 内部是负数，所以 d < 0 时 fillAlpha = 1
                    float fillAlpha = 1.0 - smoothstep(-aa, aa, d);
                    finalColor = _FillColor * fillAlpha;
                #endif

                // --- 描边 (Stroke) ---
                #if _USESTROKE_ON
                    float d_stroke = d;
                    float halfWidth = _StrokeWidth * 0.5;

                    // 对齐逻辑
                    #if defined(_STROKEALIGN_INNER)
                         d_stroke += halfWidth;
                    #elif defined(_STROKEALIGN_OUTER)
                         d_stroke -= halfWidth;
                    #endif
                    
                    float distToStroke = abs(d_stroke) - halfWidth;
                    
                    // 描边 Alpha
                    // distToStroke < 0 时显示描边
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