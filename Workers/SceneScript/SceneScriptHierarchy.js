// Original bounded 2D graph operations. No renderer or upstream engine source.
(function (options) {
  'use strict';
  const {getLayers,data,Vec3}=options,identity=[1,0,0,1,0,0];
  const integer=x=>typeof x==='number'&&Number.isInteger(x)&&x>=0&&x<=2147483647;
  function local(node){const angle=node.angles.z*Math.PI/180,c=Math.cos(angle),s=Math.sin(angle);return [c*node.scale.x,s*node.scale.x,-s*node.scale.y,c*node.scale.y,node.origin.x,node.origin.y];}
  function multiply(p,l){return [p[0]*l[0]+p[2]*l[1],p[1]*l[0]+p[3]*l[1],p[0]*l[2]+p[2]*l[3],p[1]*l[2]+p[3]*l[3],p[0]*l[4]+p[2]*l[5]+p[4],p[1]*l[4]+p[3]*l[5]+p[5]];}
  function worldStates(overrides=new Map()){
    const layers=getLayers(),index=new Map(),resolved=new Map(),visiting=new Set();
    if(layers.length>512)throw Error('Scene hierarchy has too many nodes');
    for(const layer of layers){const node=overrides.get(data(layer).id)||data(layer);if(!integer(node.id)||index.has(node.id))throw Error('Scene hierarchy has invalid or duplicate IDs');index.set(node.id,node);}
    function resolve(id){
      if(resolved.has(id))return resolved.get(id);
      const node=index.get(id);if(!node||visiting.has(id))throw Error('Scene hierarchy has a missing parent or cycle');
      visiting.add(id);
      if(visiting.size>64)throw Error('Scene hierarchy exceeds 64 levels');
      const values=[node.origin.x,node.origin.y,node.origin.z,node.angles.x,node.angles.y,node.angles.z,node.scale.x,node.scale.y,node.scale.z];
      if(values.some(x=>!Number.isFinite(x)||Math.abs(x)>1000000)||node.origin.z!==0||node.angles.x!==0||node.angles.y!==0||node.scale.z!==1)throw Error('Invalid Scene hierarchy transform');
      const parent=node.parentID===null||node.parentID===undefined?null:node.parentID;
      if(parent!==null&&!integer(parent))throw Error('Invalid Scene parent ID');
      const ancestor=parent===null?{matrix:identity,visible:true,depth:0}:resolve(parent);
      const result={matrix:multiply(ancestor.matrix,local(node)),visible:ancestor.visible&&node.visible,depth:ancestor.depth+1};
      if(result.depth>64||result.matrix.some(x=>!Number.isFinite(x)||Math.abs(x)>1000000000000))throw Error('Scene hierarchy exceeds finite world matrix budget');
      visiting.delete(id);resolved.set(id,result);return result;
    }
    for(const id of index.keys())resolve(id);
    return resolved;
  }
  function find(reference){
    const layers=getLayers();
    if(typeof reference==='number')return layers.find(x=>data(x).id===reference);
    if(typeof reference==='string')return layers.find(x=>data(x).name===reference);
    if(reference&&layers.includes(reference))return reference;
    return undefined;
  }
  function relativeTransform(parent,world){
    // Normalize before solving: small uniform scales are well-conditioned, and
    // their determinant must not underflow or be compared with an absolute 1.
    const magnitude=Math.max(...parent.slice(0,4).map(Math.abs));
    if(!(magnitude>0))throw Error('Cannot preserve world transform under a singular parent');
    const [a,b,c,d]=parent.slice(0,4).map(x=>x/magnitude),ad=a*d,bc=b*c,det=ad-bc;
    if(!Number.isFinite(det)||Math.abs(det)<=Number.EPSILON*Math.max(Math.abs(ad),Math.abs(bc)))throw Error('Cannot preserve world transform under a singular or numerically unstable parent');
    // Solve P.local=world directly rather than constructing a possibly
    // overflowing inverse when both world and parent have very small scales.
    const solve=(x,y)=>{x/=magnitude;y/=magnitude;return [(d*x-c*y)/det,(a*y-b*x)/det];};
    return [...solve(world[0],world[1]),...solve(world[2],world[3]),...solve(world[4]-parent[4],world[5]-parent[5])];
  }
  function decompose(matrix){
    const [a,b,c,d,tx,ty]=matrix;let sx=Math.hypot(a,b),sy,angle;
    if(sx>0){angle=Math.atan2(b,a);sy=(a/sx)*d-(b/sx)*c;}
    else{sx=0;sy=Math.hypot(c,d);angle=sy>0?Math.atan2(-c,d):0;}
    const result={origin:new Vec3(tx,ty,0),angles:new Vec3(0,0,angle*180/Math.PI),scale:new Vec3(sx,sy,1)};
    const reconstructed=local(result),tolerance=1e-9*Math.max(...matrix.slice(0,4).map(Math.abs));
    if(reconstructed.some((value,index)=>Math.abs(value-matrix[index])>tolerance))throw Error('Preserving this world transform requires unsupported local shear');
    return result;
  }
  function setParent(child,reference,adjust=false,attachment){
    if(typeof adjust!=='boolean'||attachment!==undefined)throw Error('Parent attachments are not supported');
    const node=data(child);if(!node)throw Error('Unknown Scene child layer');
    const parent=reference===undefined?undefined:find(reference);
    if(reference!==undefined&&!parent)throw Error('Unknown Scene parent layer');
    const parentID=parent?data(parent).id:null;
    if(parentID===node.id)throw Error('A Scene layer cannot parent itself');
    const candidate={...node,parentID};
    // Reject cycles before attempting any inverse or changing the live graph.
    const overrides=new Map([[node.id,candidate]]);worldStates(overrides);
    if(adjust){const previous=worldStates(),parentMatrix=parent?previous.get(parentID).matrix:identity;Object.assign(candidate,decompose(relativeTransform(parentMatrix,previous.get(node.id).matrix)));worldStates(overrides);}
    node.parentID=parentID;
    if(adjust){node.origin=candidate.origin;node.angles=candidate.angles;node.scale=candidate.scale;}
  }
  return Object.freeze({
    validate(){worldStates();},
    find,
    getParent(layer){const id=data(layer).parentID;return id===null||id===undefined?undefined:find(id);},
    getChildren(layer){return getLayers().filter(x=>data(x).parentID===data(layer).id);},
    setParent
  });
})
