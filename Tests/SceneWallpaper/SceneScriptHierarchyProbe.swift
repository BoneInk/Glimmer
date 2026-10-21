import Foundation

@main @MainActor enum SceneScriptHierarchyProbe {
    static let worker=URL(fileURLWithPath:CommandLine.arguments[1])
    static var passed=0, javascriptChecks=0
    static var failures:[String:String]=[:]
    static func check(_ condition:Bool,_ name:String)throws {
        guard condition else{throw SceneWallpaperFailure(message:name)};passed+=1
    }
    static func node(_ id:Int,parent:Int?=nil,group:Bool=false,x:Double=0,y:Double=0,angle:Double=0,sx:Double=1,sy:Double=1)->SceneScriptLayerState {
        .init(id:id,name:"node\(id)",origin:.init(x:x,y:y,z:0),angles:.init(x:0,y:0,z:angle),scale:.init(x:sx,y:sy,z:1),size:.init(x:1,y:1),color:.init(x:1,y:1,z:1),alpha:1,visible:true,parentID:parent,isTransformOnly:group)
    }
    static let support = #"""
    let checks=0;
    function ok(condition,message){if(!condition)throw Error(message);checks++;}
    function state(){return JSON.stringify(thisScene.enumerateLayers().map(x=>[x.id,x.name,x.isTransformOnly,x.getParent()?.id??null,x.origin.toString(),x.angles.toString(),x.scale.toString(),x.visible]));}
    function refused(action,reason){const before=state();let error;try{action();}catch(e){error=e;}ok(!!error,'operation unexpectedly succeeded: '+reason);ok(String(error).includes(reason),'wrong rejection '+error+' expected '+reason);ok(before===state(),'failed operation changed live graph: '+reason);}
    """#
    static func program(_ nodes:[SceneScriptLayerState],_ source:String,direct:[SceneScriptDirectBindingSpec]=[])->SceneScriptProgram {
        .init(bindings:[.init(id:"test",layerID:0,target:"alpha",source:source,initialValue:.number(1),scriptProperties:[:])],layers:nodes,directBindings:direct)
    }
    static func run(_ name:String,nodes:[SceneScriptLayerState],body:String,verify:@MainActor (SceneScriptFrame)throws->Void = {_ in})async {
        let client=SceneScriptWorkerClient(executableURL:worker)
        do {
            let source=support+"\nexport function init(){\n"+body+"\nthisLayer.origin.x=checks;}"
            let frame=try await client.configure(program:program(nodes,source),userProperties:Data("{}".utf8))
            try check(frame.layers.count==nodes.count,name+" valid response frame")
            if let marker=frame.layers.first(where:{$0.id==0}) {javascriptChecks+=Int(marker.origin.x)}
            try verify(frame)
            print("PASS \(name)")
        } catch {failures[name]=error.localizedDescription;print("FAIL \(name): \(error.localizedDescription)")}
        await client.dispose()
    }
    // Independent point-wise composition instead of calling production affine
    // helpers: apply each local S, then R, then T from leaf up to root.
    static func worldPoints(_ nodes:[SceneScriptLayerState],id:Int)throws->[[Double]] {
        let index=Dictionary(uniqueKeysWithValues:nodes.map{($0.id,$0)})
        return try [[0.0,0.0],[1,0],[0,1],[2,-3]].map { point in
            var p=point,current:Int?=id,visited=Set<Int>()
            while let key=current {
                guard let n=index[key],visited.insert(key).inserted else{throw SceneWallpaperFailure(message:"invalid independent graph")}
                let x=p[0]*n.scale.x,y=p[1]*n.scale.y,r=n.angles.z*Double.pi/180
                p=[x*cos(r)-y*sin(r)+n.origin.x,x*sin(r)+y*cos(r)+n.origin.y];current=n.parentID
            }
            return p
        }
    }
    static func sameWorld(_ before:[SceneScriptLayerState],_ after:[SceneScriptLayerState],id:Int)throws {
        let a=try worldPoints(before,id:id),b=try worldPoints(after,id:id)
        for (x,y) in zip(a,b){for (c,d) in zip(x,y){try check(abs(c-d)<1e-7,"adjust preserves independently composed world point")}}
    }
    static func functional()async {
        let base=[node(0),node(1,group:true,x:100,y:200,angle:30,sx:2,sy:2),node(2,group:true,x:-50,y:80,angle:-20,sx:3,sy:3),node(3,parent:1,x:10,y:5,angle:15,sx:0.5,sy:1.5),node(4,parent:3)]
        await run("hierarchy enumeration and live child-list snapshots",nodes:base,body:#"""
        ok(thisScene.getLayerCount()===5,'node count');
        const all=thisScene.enumerateLayers();ok(all.map(x=>x.id).join(',')==='0,1,2,3,4','scene order');all.pop();ok(thisScene.getLayerCount()===5,'enumeration copy');
        const g=thisScene.getLayer(1),c=thisScene.getLayer('node3');ok(g.isTransformOnly&&c.getParent()===g,'parent proxy');ok(g.getParent()===undefined,'root parent');
        const old=g.getChildren();ok(old.length===1&&old[0]===c,'initial children');c.setParent(2);
        ok(old.length===1&&old[0]===c,'old children snapshot');ok(g.getChildren().length===0,'fresh old-parent children');
        const children=thisScene.getLayer(2).getChildren();ok(children.length===1&&children[0]===c,'fresh new-parent children');children.pop();ok(thisScene.getLayer(2).getChildren().length===1,'children copy');
        ok(thisScene.getLayer(999)===undefined,'missing lookup');
        """#,verify:{f in try check(f.layers[3].parentID==2 && f.layers[3].origin==base[3].origin && f.layers[3].angles==base[3].angles && f.layers[3].scale==base[3].scale,"default reparent preserves local TRS")})
        await run("ID name proxy detach parent references",nodes:base,body:#"""
        const c=thisScene.getLayer(3);c.setParent('node2');ok(c.getParent()===thisScene.getLayer(2),'name reference');c.setParent(thisScene.getLayer(1));ok(c.getParent().id===1,'proxy reference');c.setParent(undefined);ok(c.getParent()===undefined,'detach');c.setParent(2,false);ok(c.getParent().id===2,'numeric reference');
        """#,verify:{f in try check(f.layers[3].parentID==2 && f.layers[3].origin==base[3].origin,"reference operations preserve local origin")})
        await run("adjust true reparent preserves world",nodes:base,body:"thisScene.getLayer(3).setParent(2,true);ok(thisScene.getLayer(3).getParent().id===2,'new parent');",verify:{f in try sameWorld(base,f.layers,id:3);try sameWorld(base,f.layers,id:4)})
        await run("adjust true detach preserves world",nodes:base,body:"thisScene.getLayer(3).setParent(undefined,true);ok(thisScene.getLayer(3).getParent()===undefined,'detached');",verify:{f in try sameWorld(base,f.layers,id:3);try sameWorld(base,f.layers,id:4)})
        let mirror=[node(0),node(1,group:true,x:20,y:40,angle:30,sx:-2,sy:2),node(2,group:true,sx:3,sy:3),node(3,parent:1,x:10,y:20,angle:15,sx:0.5,sy:1.5)]
        await run("mirrored world is representable TRS",nodes:mirror,body:"thisScene.getLayer(3).setParent(2,true);ok(thisScene.getLayer(3).scale.x*thisScene.getLayer(3).scale.y<0,'mirror retained');",verify:{f in try sameWorld(mirror,f.layers,id:3)})
        let zero=[node(0),node(1,group:true,x:10,y:20,sx:0,sy:-2),node(2),node(3,angle:20,sx:0,sy:0)]
        await run("singular parent rejects adjust but normal parenting and zero scale work",nodes:zero,body:#"""
        const c=thisScene.getLayer(2);refused(()=>c.setParent(1,true),'singular');c.setParent(1);ok(c.getParent().id===1,'normal singular parent');c.setParent(undefined);ok(c.getParent()===undefined,'normal detach');
        thisScene.getLayer(3).setParent(2,true);ok(thisScene.getLayer(3).scale.x===0&&thisScene.getLayer(3).scale.y===0,'degenerate child retained');
        """#,verify:{f in try sameWorld(zero,f.layers,id:3)})
        let tiny=[node(0),node(1,group:true,sx:2,sy:2),node(2,angle:31,sx:1e-14,sy:2e-14)]
        await run("tiny nonzero scales are not rounded into zero",nodes:tiny,body:"thisScene.getLayer(2).setParent(1,true);",verify:{f in
            let n=f.layers[2];try check(abs(n.scale.x-5e-15)<1e-25 && abs(n.scale.y-1e-14)<1e-25,"tiny TRS magnitudes preserved")
            try check(abs(n.angles.z-31)<1e-10,"tiny TRS rotation preserved")
        })
        let tinyParent=[node(0),node(1,group:true,sx:1e-8,sy:1e-8),node(2,angle:25,sx:1e-10,sy:2e-10)]
        await run("tiny well-conditioned invertible parent supports bounded adjustment",nodes:tinyParent,body:"thisScene.getLayer(2).setParent(1,true);",verify:{f in
            let n=f.layers[2];try check(abs(n.scale.x-0.01)<1e-12 && abs(n.scale.y-0.02)<1e-12,"tiny parent inverse produces bounded representable local scale")
            try check(abs(n.angles.z-25)<1e-10,"tiny parent preserves local rotation")
        })
        let subnormalDetParent=[node(0),node(1,group:true,sx:1e-160,sy:1e-160),node(2,angle:25,sx:1e-162,sy:2e-162)]
        await run("underflow-sized uniform parent solves relative transform without inverse overflow",nodes:subnormalDetParent,body:"thisScene.getLayer(2).setParent(1,true);",verify:{f in
            let n=f.layers[2];try check(abs(n.scale.x-0.01)<1e-12 && abs(n.scale.y-0.02)<1e-12,"1e-160 parent and 1e-162 child give finite .01/.02 local scales")
            try check(abs(n.angles.z-25)<1e-10 && n.parentID==1,"extremely tiny parent preserves rotation and identity")
        })
        let underflowChild=[node(0),node(1,group:true),node(2,angle:31,sx:1e-162,sy:2e-162)]
        await run("decomposition keeps tiny second scale despite determinant underflow",nodes:underflowChild,body:"thisScene.getLayer(2).setParent(1,true);",verify:{f in
            let n=f.layers[2];try check(abs(n.scale.x/1e-162-1)<1e-12 && abs(n.scale.y/2e-162-1)<1e-12,"tiny nonzero XY scales survive without determinant product")
            try check(abs(n.angles.z-31)<1e-10,"extremely tiny local rotation preserved")
        })
        let tinyLocalShear=[node(0),node(1,group:true,sx:1,sy:1.1),node(2,angle:45,sx:1e-12,sy:2e-12)]
        await run("tiny local shear cannot hide behind absolute tolerance",nodes:tinyLocalShear,body:"refused(()=>thisScene.getLayer(2).setParent(1,true),'shear');",verify:{f in
            let n=f.layers[2];try check(n.parentID==nil && n.origin==tinyLocalShear[2].origin && n.scale==tinyLocalShear[2].scale && n.angles==tinyLocalShear[2].angles,"tiny-shear failure leaves exact local graph state unchanged")
        })
        let shear=[node(0),node(1,group:true,sx:2,sy:1),node(2,parent:1,angle:45)]
        await run("existing ancestor shear cannot flatten into local TRS",nodes:shear,body:"refused(()=>thisScene.getLayer(2).setParent(undefined,true),'shear');")
        let targetShear=[node(0),node(1,group:true,sx:2,sy:1),node(2,angle:45)]
        await run("new ancestor shear rejects atomically",nodes:targetShear,body:"refused(()=>thisScene.getLayer(2).setParent(1,true),'shear');")
        let tinyShear=[node(0),node(1,group:true,sx:1,sy:1.0001),node(2,x:1_000_000,angle:45)]
        await run("large translation cannot hide nonrepresentable shear",nodes:tinyShear,body:"refused(()=>thisScene.getLayer(2).setParent(1,true),'shear');",verify:{f in try sameWorld(tinyShear,f.layers,id:2);try check(f.layers[2].parentID==nil && !f.layers[2].isTransformOnly,"far-origin failed adjustment preserves metadata")})
        await run("invalid references cycles and attachment overloads are atomic",nodes:base,body:#"""
        const c=thisScene.getLayer(3),p=thisScene.getLayer(1);
        refused(()=>c.setParent(999),'Unknown');refused(()=>c.setParent('absent'),'Unknown');refused(()=>c.setParent({id:1}),'Unknown');refused(()=>c.setParent(null),'Unknown');
        refused(()=>c.setParent(c),'itself');refused(()=>p.setParent(c),'cycle');refused(()=>c.setParent(2,'bone',true),'attachments');refused(()=>c.setParent(2,false,'bone'),'attachments');
        """#)
        await run("readonly identity and kind cannot be forged",nodes:base,body:#"""
        const c=thisScene.getLayer(3);
        for(const key of ['id','name','parentID','isTransformOnly']){
          refused(()=>{c[key]=key==='name'?'forged':true;},'Unsupported');
          refused(()=>Object.defineProperty(c,key,{value:99}),'redefined');
          refused(()=>{delete c[key];},'deleted');
        }
        refused(()=>Object.setPrototypeOf(c,{}),'prototypes');refused(()=>Object.preventExtensions(c),'extensibility');refused(()=>Object.seal(c),'extensibility');refused(()=>Object.freeze(c),'extensibility');
        """#)
        await run("groups reject all image-property reads and writes",nodes:base,body:#"""
        const g=thisScene.getLayer(1);for(const key of ['alpha','color','size']){refused(()=>g[key],'Transform-only');refused(()=>{g[key]=1;},'Unsupported');}
        """#,verify:{f in let g=f.layers[1];try check(g.size==SceneVector2(x:1,y:1)&&g.color==SceneVector3(x:1,y:1,z:1)&&g.alpha==1,"group frame placeholders stay fixed")})
        await run("reflection cannot expose group image-property values",nodes:base,body:#"""
        const g=thisScene.getLayer(1),keys=Object.keys(g),all=Reflect.ownKeys(g);
        for(const key of ['alpha','color','size']){ok(!keys.includes(key)&&!all.includes(key),'group keys hide image fields');ok(Object.getOwnPropertyDescriptor(g,key)===undefined,'group descriptor hides placeholder');}
        for(const key of ['id','name','parentID','isTransformOnly'])ok(Object.getOwnPropertyDescriptor(g,key).writable===false,'readonly metadata descriptor');
        ok(Object.getOwnPropertyDescriptor(g,'origin').value===g.origin,'normal shape descriptor remains usable');
        g.origin=new Vec3(8,9,0);g.origin.x=10;ok(g.origin.x===10&&g.origin.y===9,'normal shape fields still writable');
        """#)
        var deep=[node(0)];deep += (1...63).map{node($0,parent:$0==1 ? nil:$0-1,group:true)};deep += [node(64,parent:63),node(65,group:true)]
        await run("depth overflow reparent is caught without altering graph",nodes:deep,body:"refused(()=>thisScene.getLayer(65).setParent(64),'hierarchy');")
        let huge=[node(0),node(1,group:true,sx:1_000_000,sy:1_000_000),node(2,parent:1,group:true,sx:1_000_000,sy:1_000_000),node(3,sx:2,sy:2)]
        await run("world matrix bound enforced atomically",nodes:huge,body:"refused(()=>thisScene.getLayer(3).setParent(2),'budget');")
        let localBound=[node(0),node(1,group:true,x:-1_000_000),node(2,x:1_000_000)]
        await run("adjust local transform bound enforced atomically",nodes:localBound,body:"refused(()=>thisScene.getLayer(2).setParent(1,true),'transform');")
        let maximum=(0..<512).map{node($0,group:$0 != 0)}
        await run("512 node graph remains bounded and addressable",nodes:maximum,body:"ok(thisScene.getLayerCount()===512,'512 count');ok(thisScene.getLayer(511).getParent()===undefined,'512th node');")
    }
    static func groupUpdates()async {
        let client=SceneScriptWorkerClient(executableURL:worker)
        do {
            let nodes=[node(0),node(1,group:true),node(2,parent:1)]
            let source="export function update(v){const g=thisScene.getLayer(1);g.origin=g.origin.add(new Vec3(1,0,0));g.angles=new Vec3(0,0,engine.runtime*10);g.scale=new Vec3(-2,0,1);g.visible=!g.visible;}"
            let direct=[("origin","off"),("angles","rot"),("scale","stretch"),("visible","show")].map{SceneScriptDirectBindingSpec(layerID:1,target:$0.0,propertyKey:$0.1)}
            let props=Data(#"{"off":{"value":"20 30 0"},"rot":{"value":"0 0 15"},"stretch":{"value":"2 3 1"},"show":{"value":false}}"#.utf8)
            var f=try await client.configure(program:program(nodes,source,direct:direct),userProperties:props)
            try check(f.layers[1].origin.x==20 && f.layers[1].angles.z==15 && f.layers[1].scale.y==3 && !f.layers[1].visible,"direct author settings update actual group fields")
            f=try await client.applyUserProperties(Data(#"{"off":{"value":"40 50 0"},"rot":{"value":"0 0 25"},"stretch":{"value":"3 4 1"},"show":{"value":true}}"#.utf8),runtime:1)
            try check(f.layers[1].origin.x==40 && f.layers[1].scale.y==4 && f.layers[1].visible,"later direct group settings ACK actual state")
            f=try await client.step(runtime:2,frameTime:0.1)
            let g=f.layers[1]
            try check(g.origin.x==41 && g.origin.y==50 && g.angles.z==20 && g.scale.x == -2 && g.scale.y==0 && !g.visible,"real update mutates only supported group fields including mirror and zero scale")
            try check(g.isTransformOnly && g.alpha==1 && g.size==SceneVector2(x:1,y:1) && g.color==SceneVector3(x:1,y:1,z:1),"group updates preserve image-only transport placeholders")
            print("PASS group direct settings and update")
        }catch{failures["group updates"]=error.localizedDescription;print("FAIL group updates: \(error)")}
        await client.dispose()
    }
    static func imageOnlyGroupAttachments() async {
        for target in ["alpha","color","size"] {
            for mode in ["script","direct"] {
                let client=SceneScriptWorkerClient(executableURL:worker)
                do {
                    let nodes=[node(0),node(1,group:true)]
                    let p:SceneScriptProgram
                    if mode=="script" {
                        p = .init(bindings:[.init(id:"bad",layerID:1,target:target,source:"export function init(value){return value;}",initialValue:.number(1),scriptProperties:[:])],layers:nodes)
                    } else {p=program(nodes,"export function init(){}",direct:[.init(layerID:1,target:target,propertyKey:"bad")])}
                    var message=""
                    do{_ = try await client.configure(program:p,userProperties:Data("{\"bad\":{\"value\":0.5}}".utf8))}catch{message=error.localizedDescription}
                    try check(message.contains(mode=="script" ? "Invalid script attachment":"Unsupported layer write"),"group \(target) \(mode) attachment rejects semantically")
                    let frame=try await client.step(runtime:0,frameTime:0)
                    try check(frame.layers[1].alpha==1 && frame.layers[1].color==SceneVector3(x:1,y:1,z:1) && frame.layers[1].size==SceneVector2(x:1,y:1),"group \(target) \(mode) failure leaves live helper and fixed dummy state")
                } catch {failures["group \(target) \(mode) attachment"]=error.localizedDescription}
                await client.dispose()
            }
        }
        print("CHECKED group image-only direct and script attachment refusal")
    }
    static func oversizedProgram()async {
        let client=SceneScriptWorkerClient(executableURL:worker)
        do {
            var message=""
            do{_ = try await client.configure(program:program((0..<513).map{node($0)},""),userProperties:Data("{}".utf8))}
            catch{message=error.localizedDescription}
            try check(message.contains("Invalid SceneScript program"),"513 nodes rejected by semantic program validation, never timeout or disconnection")
            let alive=try await client.step(runtime:0,frameTime:0)
            try check(alive.layers.isEmpty,"helper still responds to valid RPC after oversized-program rejection")
            print("PASS explicit 513-node program rejection with live IPC")
        }catch{failures["513-node program"]=error.localizedDescription}
        await client.dispose()
    }
    static func receiverValidation()throws {
        let originals=[node(0),node(1,group:true),node(2,parent:1)]
        func layer(_ s:SceneScriptLayerState)->SceneImageLayer{.init(id:s.id,name:s.name,modelPath:s.isTransformOnly ? "":"m",materialPath:s.isTransformOnly ? "":"p",texturePath:s.isTransformOnly ? "":"t",origin:s.origin,anglesDegrees:s.angles,scale:s.scale,size:s.size,tint:s.color,opacity:s.alpha,isVisible:s.visible,bindings:[],parentID:s.parentID,isTransformOnly:s.isTransformOnly)}
        let texture=SceneTextureAsset(path:"t",format:.rgba8888,flags:0,data:Data(repeating:255,count:4),storageWidth:1,storageHeight:1,imageWidth:1,imageHeight:1)
        let inspection=SceneWallpaperInspection(canvasSize:.init(x:10,y:10),clearColor:.init(x:0,y:0,z:0),layers:originals.map(layer),textures:["t":texture],diagnostics:[])
        for (name,changed) in [("forged ID",node(99)),("forged kind",node(2,parent:1,group:true)),("missing parent",node(2,parent:999)),("self parent",node(2,parent:2))]{
            var states=originals;states[2]=changed;var failed=false
            do{_ = try inspection.applyingScriptFrame(.init(layers:states,hasUpdateHandlers:false,canApplyUserProperties:false))}catch{failed=true}
            try check(failed,"Swift receiver rejects \(name)")
        }
        var changed=originals;changed[2]=node(2)
        let updated=try inspection.applyingScriptFrame(.init(layers:changed,hasUpdateHandlers:false,canApplyUserProperties:false))
        try check(updated.layers[2].parentID==nil,"Swift receiver accepts validated legitimate parent change")
        print("PASS independent Swift frame graph and kind validation")
    }
    static func noOwnChildren() async throws {
        for _ in 0..<200 {
            let p=Process();p.executableURL=URL(fileURLWithPath:"/bin/ps");p.arguments=["-axo","ppid=,comm="]
            let output=Pipe();p.standardOutput=output;try p.run()
            let bytes=output.fileHandleForReading.readDataToEndOfFile();p.waitUntilExit()
            let own=String(decoding:bytes,as:UTF8.self).split(separator:"\n").contains{line in
                let fields=line.split(whereSeparator:{$0 == " " || $0 == "\t"})
                return fields.count>=2 && Int32(fields[0])==getpid() && fields.dropFirst().joined(separator:" ").hasSuffix("GlimmerSceneScriptWorker")
            }
            if !own {try check(true,"all own helper children terminated");return}
            try await Task.sleep(for:.milliseconds(10))
        }
        throw SceneWallpaperFailure(message:"Own helper child remained after dispose")
    }
    static func main()async {
        await functional();await groupUpdates();await imageOnlyGroupAttachments();await oversizedProgram()
        do{try receiverValidation()}catch{failures["Swift receiver"]=error.localizedDescription}
        do{try await noOwnChildren()}catch{failures["process cleanup"]=error.localizedDescription}
        let object:[String:Any]=["passed":passed,"javascriptAssertions":javascriptChecks,"failures":failures,"mode":"real copied helper IPC/JSC; independent point-wise transform validation; no GUI","worker":worker.path]
        do{let bytes=try JSONSerialization.data(withJSONObject:object,options:[.prettyPrinted,.sortedKeys]);try bytes.write(to:URL(fileURLWithPath:CommandLine.arguments[2]));print(String(decoding:bytes,as:UTF8.self))}catch{print(error);exit(2)}
        if !failures.isEmpty{exit(1)}
    }
}
