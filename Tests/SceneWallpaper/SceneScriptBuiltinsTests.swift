import Foundation
import JavaScriptCore

@main struct SceneScriptBuiltinsTests {
    static func main() throws {
        guard let context=JSContext() else { throw NSError(domain:"BuiltinsProbe",code:1) }
        let source=try String(contentsOfFile:CommandLine.arguments[1],encoding:.utf8)
        guard let factory=context.evaluateScript(source), !factory.isUndefined, context.exception == nil else {
            throw NSError(domain:"BuiltinsProbe",code:2,userInfo:[NSLocalizedDescriptionKey:"Factory parse failed"])
        }
        context.setObject(factory,forKeyedSubscript:"moduleFactory" as NSString)
        let tests = #"""
        (() => {
            'use strict';
            // Constructor injection is deliberately observable. These are test
            // value types, not an alternate execution engine or scalar model.
            class Vec2 {
                constructor(x,y){this.x=x;this.y=y;}
                copy(){return new Vec2(this.x,this.y);}
            }
            class Vec3 {
                constructor(x,y,z){this.x=x;this.y=y;this.z=z;}
                copy(){return new Vec3(this.x,this.y,this.z);}
            }
            let checks=0;
            function ok(value,name){if(!value)throw Error(name);checks++;}
            function near(a,b,name,epsilon=1e-11){ok(Number.isFinite(a)&&Math.abs(a-b)<=epsilon,name+': '+a+' expected '+b);}
            function vector(v,values,Type,name){
                ok(v instanceof Type && Object.getPrototypeOf(v)===Type.prototype,name+' injected prototype');
                for(let i=0;i<values.length;i++)near(v[['x','y','z'][i]],values[i],name+' component '+i);
                const copy=v.copy();ok(copy instanceof Type&&copy!==v,name+' independent typed copy');
                const x=v.x;copy.x=99;ok(v.x===x,name+' copy mutation isolation');
            }
            const modules=moduleFactory(Vec2,Vec3),{WEMath,WEColor,WEVector}=modules;
            ok(Object.isFrozen(modules)&&Object.values(modules).every(Object.isFrozen),'frozen module namespaces');
            ok(Object.keys(WEMath).sort().join(',')==='deg2rad,mix,rad2deg,smoothStep','complete Math surface');
            ok(Object.keys(WEColor).sort().join(',')==='expandColor,hsv2rgb,normalizeColor,rgb2hsv','complete Color surface');
            ok(Object.keys(WEVector).sort().join(',')==='angleVector2,vectorAngle2','complete Vector surface');
            near(WEMath.deg2rad*180,Math.PI,'degree factor');near(WEMath.rad2deg*Math.PI,180,'radian factor');
            near(WEMath.deg2rad*WEMath.rad2deg,1,'reciprocal factors');
            for(const [v,expected] of [[-1,0],[0,0],[.25,.15625],[.5,.5],[.75,.84375],[1,1],[2,1]])near(WEMath.smoothStep(0,1,v),expected,'cubic smoothStep '+v);
            near(WEMath.smoothStep(2,6,3),.15625,'smoothStep non-unit interval');
            near(WEMath.smoothStep(2,2,1),0,'equal edge below local convention');
            near(WEMath.smoothStep(2,2,2),1,'equal edge inclusive local convention');
            near(WEMath.smoothStep(2,2,3),1,'equal edge above local convention');
            near(WEMath.smoothStep(1,0,.25),.84375,'reversed edges local convention');
            let last=-1;for(let i=0;i<=100;i++){const next=WEMath.smoothStep(0,1,i/100);ok(next>=last&&next>=0&&next<=1,'bounded monotonic smoothStep');last=next;}
            ok(WEMath.smoothStep(0,1,.0001)<1e-6&&1-WEMath.smoothStep(0,1,.9999)<1e-6,'smooth endpoints');
            for(const [t,expected] of [[0,2],[1,6],[.25,3],[-1,-2],[2,10]])near(WEMath.mix(2,6,t),expected,'mix including extrapolation');
            const colors=[[[1,0,0],[0,1,1]],[[0,1,0],[1/3,1,1]],[[0,0,1],[2/3,1,1]],[[1,1,0],[1/6,1,1]],[[0,1,1],[.5,1,1]],[[1,0,1],[5/6,1,1]],[[0,0,0],[0,0,0]],[[1,1,1],[0,0,1]],[[.4,.4,.4],[0,0,.4]],[[.25,.5,.75],[7/12,2/3,.75]]];
            for(const [rgb,hsv] of colors){
                const input=Object.freeze(new Vec3(...rgb));
                vector(WEColor.rgb2hsv(input),hsv,Vec3,'known RGB to HSV');
                vector(WEColor.hsv2rgb(Object.freeze(new Vec3(...hsv))),rgb,Vec3,'known HSV to RGB');
                ok(input.x===rgb[0]&&input.y===rgb[1]&&input.z===rgb[2],'RGB input immutable');
            }
            vector(WEColor.hsv2rgb(new Vec3(.5,.6,.8)),[.32,.8,.8],Vec3,'mixed saturation and value');
            for(const hue of [-2,-1,0,1,2])vector(WEColor.hsv2rgb(new Vec3(hue,1,1)),[1,0,0],Vec3,'integer hue wrap');
            vector(WEColor.hsv2rgb(new Vec3(-1/6,1,1)),[1,0,1],Vec3,'negative hue wrap');
            vector(WEColor.hsv2rgb(new Vec3(7/6,1,1)),[1,1,0],Vec3,'positive hue wrap');
            const raw=Object.freeze(new Vec3(255,127.5,0));
            vector(WEColor.normalizeColor(raw),[1,.5,0],Vec3,'normalize color');
            vector(WEColor.expandColor(Object.freeze(new Vec3(.5,.25,1))),[127.5,63.75,255],Vec3,'expand does not quantize');
            vector(WEColor.expandColor(new Vec3(-.1,1.1,2)),[-25.5,280.5,510],Vec3,'scale does not clamp local convention');
            ok(raw.x===255&&raw.y===127.5&&raw.z===0,'normalization input preserved');
            // Deterministic sweep exercises all hue sectors and nontrivial RGB
            // coordinates, supplementing independent known primary expectations.
            for(let r=0;r<=5;r++)for(let g=0;g<=5;g++)for(let b=0;b<=5;b++){
                const rgb=new Vec3(r/5,g/5,b/5),hsv=WEColor.rgb2hsv(rgb),round=WEColor.hsv2rgb(hsv);
                ok(hsv.x>=0&&hsv.x<1&&hsv.y>=0&&hsv.y<=1&&hsv.z>=0&&hsv.z<=1,'normalized HSV range');
                near(round.x,rgb.x,'RGB round trip R');near(round.y,rgb.y,'RGB round trip G');near(round.z,rgb.z,'RGB round trip B');
            }
            for(const [angle,xy] of [[0,[1,0]],[90,[0,1]],[180,[-1,0]],[270,[0,-1]],[-90,[0,-1]],[360,[1,0]],[45,[Math.SQRT1_2,Math.SQRT1_2]]])vector(WEVector.angleVector2(angle),xy,Vec2,'angle to vector '+angle);
            for(const [xy,angle] of [[[1,0],0],[[0,1],90],[[-1,0],180],[[0,-1],-90],[[2,2],45],[[0,0],0]]){
                const value=Object.freeze(new Vec2(...xy));near(WEVector.vectorAngle2(value),angle,'vector angle convention');ok(value.x===xy[0]&&value.y===xy[1],'direction not mutated');
            }
            for(let angle=-720;angle<=720;angle+=15){
                const v=WEVector.angleVector2(angle);near(Math.hypot(v.x,v.y),1,'unit directional vector');
                const result=WEVector.vectorAngle2(v),delta=((result-angle)%360+540)%360-180;near(delta,0,'angle periodic round trip',1e-9);
            }
            const second=moduleFactory(Vec2,Vec3);ok(second!==modules&&second.WEColor!==WEColor,'fresh module namespace per factory');
            return {passed:checks,engine:'real JavaScriptCore',constructorInjection:'test Vec2/Vec3 with prototype and copy sentinels',windowsParityClaim:false};
        })()
        """#
        let result=context.evaluateScript(tests)
        if let exception=context.exception {
            throw NSError(domain:"BuiltinsProbe",code:3,userInfo:[NSLocalizedDescriptionKey:exception.toString() ?? "JS exception"])
        }
        guard let object=result?.toDictionary() else {throw NSError(domain:"BuiltinsProbe",code:4)}
        let data=try JSONSerialization.data(withJSONObject:object,options:[.prettyPrinted,.sortedKeys]);print(String(decoding:data,as:UTF8.self))
    }
}
