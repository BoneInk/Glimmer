import Foundation

/// Column-vector affine matrix: x'=a*x+c*y+tx, y'=b*x+d*y+ty.
struct SceneAffineTransform: Equatable, Sendable {
    let a: Double
    let b: Double
    let c: Double
    let d: Double
    let tx: Double
    let ty: Double
    static let identity = Self(a:1,b:0,c:0,d:1,tx:0,ty:0)
    func concatenating(_ local: Self) -> Self {
        Self(a:a*local.a+c*local.b,b:b*local.a+d*local.b,
             c:a*local.c+c*local.d,d:b*local.c+d*local.d,
             tx:a*local.tx+c*local.ty+tx,ty:b*local.tx+d*local.ty+ty)
    }
}
struct SceneLayerWorldState: Equatable, Sendable {
    let transform: SceneAffineTransform
    let isVisible: Bool
}
enum SceneHierarchy {
    static func validate(layers: [SceneImageLayer]) throws { _ = try worldStates(layers:layers) }
    static func worldStates(layers: [SceneImageLayer]) throws -> [Int:SceneLayerWorldState] {
        guard layers.count <= 512, Set(layers.map(\.id)).count == layers.count else {
            throw SceneWallpaperFailure(message:"Scene hierarchy has duplicate IDs or too many layers.")
        }
        let indexed=Dictionary(uniqueKeysWithValues:layers.map {($0.id,$0)})
        var result:[Int:SceneLayerWorldState]=[:], visiting=Set<Int>(), depths:[Int:Int]=[:]
        func resolve(_ id:Int) throws -> SceneLayerWorldState {
            if let value=result[id] {return value}
            guard let layer=indexed[id], visiting.insert(id).inserted else {throw SceneWallpaperFailure(message:"Scene hierarchy has a missing parent or cycle.")}
            defer {visiting.remove(id)}
            // Bound recursion even before any cached ancestor depth is known.
            guard visiting.count <= 64, layer.id >= 0, layer.id <= Int(Int32.max), layer.parentID != id,
                  [layer.origin.x,layer.origin.y,layer.origin.z,layer.anglesDegrees.x,layer.anglesDegrees.y,layer.anglesDegrees.z,layer.scale.x,layer.scale.y,layer.scale.z].allSatisfy({$0.isFinite && abs($0)<=1_000_000}),
                  layer.origin.z == 0,layer.anglesDegrees.x == 0,layer.anglesDegrees.y == 0,layer.scale.z == 1 else {
                throw SceneWallpaperFailure(message:"Scene hierarchy exceeds 64 levels or contains an invalid 2D transform.")
            }
            let angle=layer.anglesDegrees.z * .pi / 180, cosine=cos(angle), sine=sin(angle)
            let local=SceneAffineTransform(a:cosine*layer.scale.x,b:sine*layer.scale.x,c:-sine*layer.scale.y,d:cosine*layer.scale.y,tx:layer.origin.x,ty:layer.origin.y)
            let world:SceneAffineTransform, visible:Bool, depth:Int
            if let parentID=layer.parentID {
                let parent=try resolve(parentID)
                depth=(depths[parentID] ?? 0)+1
                world=parent.transform.concatenating(local);visible=parent.isVisible && layer.isVisible
            } else {depth=1;world=local;visible=layer.isVisible}
            guard depth<=64,[world.a,world.b,world.c,world.d,world.tx,world.ty].allSatisfy({$0.isFinite && abs($0)<=1_000_000_000_000}) else {
                throw SceneWallpaperFailure(message:"Scene world transform exceeds its finite matrix or hierarchy budget.")
            }
            let value=SceneLayerWorldState(transform:world,isVisible:visible)
            depths[id]=depth;result[id]=value;return value
        }
        for layer in layers {try Task.checkCancellation();_ = try resolve(layer.id)}
        return result
    }
}
