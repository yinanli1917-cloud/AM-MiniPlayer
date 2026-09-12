# glass-morph-spike results summary

Generated: Fri Sep 11 16:01:45 PDT 2026

## animated
```
VERDICT={"mode":"animated","scenario":1,"RENDER":"yes-by-equivalence","RENDER_REASON":"shared non-zero-bounds backdrop layer class(es) [\"CABackdropLayer\"] present in both the SwiftUI glassEffect tree (1 backdrop layer(s)) and the founder-verified NSGlassEffectView control tree (1 backdrop layer(s)) — same underlying glass compositing primitive","MORPH":"yes","MORPH_REASON":"a layer born after the toggle (class CABackdropLayer, birthFrame=13) shows 19 continuously-changing frame-steps between birth and settle","trackedLayerCount":2,"frameCount":38,"bornBirthFrame":13,"bornFirstW":194.90771143667988,"bornFirstH":65.59366751509447,"bornLastW":225.44223008342192,"bornLastH":79.93397723819646}
```

## no-animation
```
VERDICT={"mode":"no-animation","scenario":1,"RENDER":"yes-by-equivalence","RENDER_REASON":"shared non-zero-bounds backdrop layer class(es) [\"CABackdropLayer\"] present in both the SwiftUI glassEffect tree (1 backdrop layer(s)) and the founder-verified NSGlassEffectView control tree (1 backdrop layer(s)) — same underlying glass compositing primitive","MORPH":"no(control-lands-fast)","MORPH_REASON":"no-animation control: every tracked layer's bounds/position land within <=2 frame-steps (max born=0, max pill=0) — confirms logger can distinguish a jump from a morph","trackedLayerCount":1,"frameCount":38,"bornBirthFrame":-1,"bornFirstW":0.0,"bornFirstH":0.0,"bornLastW":0.0,"bornLastH":0.0}
```

## animated-s2
```
VERDICT={"mode":"animated","scenario":2,"RENDER":"yes-by-equivalence","RENDER_REASON":"shared non-zero-bounds backdrop layer class(es) [\"CABackdropLayer\"] present in both the SwiftUI glassEffect tree (1 backdrop layer(s)) and the founder-verified NSGlassEffectView control tree (1 backdrop layer(s)) — same underlying glass compositing primitive","MORPH":"yes","MORPH_REASON":"the pre-existing pill-side backdrop layer changes shape/position across 23 frame-steps","trackedLayerCount":1,"frameCount":38,"bornBirthFrame":-1,"bornFirstW":0.0,"bornFirstH":0.0,"bornLastW":0.0,"bornLastH":0.0}
```

## no-animation-s2
```
VERDICT={"mode":"no-animation","scenario":2,"RENDER":"yes-by-equivalence","RENDER_REASON":"shared non-zero-bounds backdrop layer class(es) [\"CABackdropLayer\"] present in both the SwiftUI glassEffect tree (1 backdrop layer(s)) and the founder-verified NSGlassEffectView control tree (1 backdrop layer(s)) — same underlying glass compositing primitive","MORPH":"no(control-lands-fast)","MORPH_REASON":"no-animation control: every tracked layer's bounds/position land within <=2 frame-steps (max born=0, max pill=0) — confirms logger can distinguish a jump from a morph","trackedLayerCount":1,"frameCount":38,"bornBirthFrame":-1,"bornFirstW":0.0,"bornFirstH":0.0,"bornLastW":0.0,"bornLastH":0.0}
```

