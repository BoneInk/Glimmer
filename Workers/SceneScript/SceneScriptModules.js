// Original synchronous ES-module linker. Acorn supplies syntax; eslint-scope
// supplies resolved references so imported identifiers retain live bindings
// without rewriting strings, property names or shadowed local variables.
(function (options) {
  'use strict';
  const {parse, analyze, builtins, sources, globals, source}=options;
  const records=new Map(), own=(o,k)=>Object.prototype.hasOwnProperty.call(o,k);
  const sourceEntries=Object.entries(sources||{});
  if(sourceEntries.length>128)throw Error('SceneScript module count exceeds 128');
  const aliases=new Set();let bytes=0;
  for(const [name,text] of sourceEntries){
    if(typeof text!=='string'||!name.endsWith('.js')||name!==name.normalize('NFC')||name.length>255||name.split('/').some(x=>!x||x==='.'||x==='..')||/[\\:\x00-\x1f\x7f]/.test(name)||name.startsWith('/'))throw Error('Invalid SceneScript module snapshot path');
    const key=name.toLowerCase();if(aliases.has(key))throw Error('Ambiguous SceneScript module path');aliases.add(key);
    bytes+=text.length;if(text.length>262144||bytes>1048576)throw Error('SceneScript module source exceeds limits');
  }
  function resolve(specifier,from){
    if(own(builtins,specifier))return 'builtin:'+specifier;
    if(typeof specifier!=='string'||!specifier||specifier.length>255||/[\\:\x00-\x1f\x7f]/.test(specifier)||specifier.startsWith('/'))throw Error('Unsafe SceneScript module specifier');
    const stack=(specifier.startsWith('./')||specifier.startsWith('../'))&&from!=='@inline'?from.split('/').slice(0,-1):[];
    for(const part of specifier.split('/')){
      if(part==='.')continue;
      if(part==='..'){if(!stack.length)throw Error('SceneScript module escapes project');stack.pop();}
      else {if(!part)throw Error('Invalid SceneScript module path');stack.push(part);}
    }
    const result=stack.join('/').normalize('NFC');
    if(!own(sources,result))throw Error('Missing SceneScript module: '+result);
    return result;
  }
  function exportName(node){return node.type==='Identifier'?node.name:node.value;}
  function patternNames(node){
    if(!node)return [];
    if(node.type==='Identifier')return [node.name];
    if(node.type==='RestElement')return patternNames(node.argument);
    if(node.type==='AssignmentPattern')return patternNames(node.left);
    if(node.type==='ArrayPattern')return node.elements.flatMap(patternNames);
    if(node.type==='ObjectPattern')return node.properties.flatMap(x=>patternNames(x.type==='RestElement'?x.argument:x.value));
    throw Error('Unsupported exported binding pattern');
  }
  function getRecord(id){
    if(records.has(id))return records.get(id);
    const record={id,namespace:Object.create(null),getters:Object.create(null),explicit:new Map(),imports:new Map(),stars:[],dependencies:[],names:new Set(),status:'linked'};
    records.set(id,record);
    if(id.startsWith('builtin:')){
      const module=builtins[id.slice(8)];
      for(const name of Object.keys(module)){record.explicit.set(name,{kind:'local',local:name});record.getters[name]=()=>module[name];}
      record.status='evaluated';return record;
    }
    const code=id==='@inline'?source:sources[id];
    const tokens=[],ast=parse(code,{ecmaVersion:2022,sourceType:'module',ranges:true,onToken:tokens}),parents=new WeakMap(),identifiers=new Set();
    function walk(node,parent,functionDepth=0){
      if(!node||typeof node!=='object'||typeof node.type!=='string')return;
      parents.set(node,parent);if(node.type==='Identifier')identifiers.add(node.name);
      if(node.type==='ImportExpression'||node.type==='MetaProperty')throw Error('Dynamic import and import.meta are not supported');
      if(node.type==='AwaitExpression'&&functionDepth===0)throw Error('Asynchronous module evaluation is not supported');
      const depth=functionDepth+(/Function/.test(node.type)||node.type==='ArrowFunctionExpression'?1:0);
      for(const key of Object.keys(node)){if(key==='range')continue;const v=node[key];if(Array.isArray(v))v.forEach(x=>walk(x,node,depth));else if(v&&typeof v==='object')walk(v,node,depth);}
    }
    walk(ast,null);
    let prefix='__gwModule';while([...identifiers].some(x=>x.startsWith(prefix)))prefix+='_';
    const host=prefix+'Host',edits=[],localGetters=new Map();let defaultCounter=0;
    function dependency(specifier){
      const id=resolve(specifier,record.id);let index=record.dependencies.indexOf(id);
      if(index<0){index=record.dependencies.length;record.dependencies.push(id);}
      return {id,index,variable:prefix+'Dependency'+index};
    }
    function localExport(name,local){record.explicit.set(name,{kind:'local',local});localGetters.set(local,local);}
    for(const node of ast.body){
      if(node.type==='ImportDeclaration'){
        const dep=dependency(node.source.value);
        for(const spec of node.specifiers)record.imports.set(spec.local.name,{...dep,imported:spec.type==='ImportNamespaceSpecifier'?'*':spec.type==='ImportDefaultSpecifier'?'default':exportName(spec.imported)});
        edits.push([node.start,node.end,'']);
      }else if(node.type==='ExportNamedDeclaration'){
        if(node.declaration){
          const d=node.declaration,names=d.type==='VariableDeclaration'?d.declarations.flatMap(x=>patternNames(x.id)):d.id?[d.id.name]:[];
          if(!names.length)throw Error('Unsupported SceneScript export declaration');
          for(const name of names)localExport(name,name);
          edits.push([node.start,d.start,'']);
        }else{
          const dep=node.source?dependency(node.source.value):null;
          for(const spec of node.specifiers){const name=exportName(spec.exported),local=exportName(spec.local);if(dep)record.explicit.set(name,{kind:'indirect',id:dep.id,imported:local});else record.explicit.set(name,{kind:'alias',local});}
          edits.push([node.start,node.end,'']);
        }
      }else if(node.type==='ExportAllDeclaration'){
        const dep=dependency(node.source.value);
        if(node.exported){const key=prefix+'Namespace'+defaultCounter++;localGetters.set(key,dep.variable);record.explicit.set(exportName(node.exported),{kind:'local',local:key});}
        else record.stars.push(dep.id);
        edits.push([node.start,node.end,'']);
      }else if(node.type==='ExportDefaultDeclaration'){
        const d=node.declaration;
        if(d.type==='FunctionDeclaration'){
          const key=d.id?d.id.name:prefix+'Default'+defaultCounter++;localExport('default',key);edits.push([node.start,d.start,'']);
          // Anonymous declarations need an identifier while remaining hoisted.
          if(!d.id){const index=tokens.findIndex(t=>t.start>=d.start&&t.end<=d.end&&t.type.label==='function');if(index<0)throw Error('Invalid default function');const token=tokens[index+1]&&tokens[index+1].type.label==='*'?tokens[index+1]:tokens[index];edits.push([token.end,token.end,' '+key+' ']);}
        }else if(d.type==='ClassDeclaration'&&d.id){localExport('default',d.id.name);edits.push([node.start,d.start,'']);}
        else{const key=prefix+'Default'+defaultCounter++;localExport('default',key);edits.push([node.start,d.start,'const '+key+' = ']);}
      }
    }
    // Resolve aliases after every import is known, including exports preceding imports.
    for(const [name,descriptor] of record.explicit){if(descriptor.kind!=='alias')continue;const imported=record.imports.get(descriptor.local);
      if(imported)record.explicit.set(name,imported.imported==='*'?{kind:'namespace',id:imported.id}:{kind:'indirect',id:imported.id,imported:imported.imported});
      else{record.explicit.set(name,{kind:'local',local:descriptor.local});localGetters.set(descriptor.local,descriptor.local);}}
    const manager=analyze(ast,{ecmaVersion:2022,sourceType:'module',optimistic:true,impliedStrict:true});
    for(const scope of manager.scopes)for(const variable of scope.variables){
      if(!variable.defs.some(x=>x.type==='ImportBinding'))continue;
      const imported=record.imports.get(variable.name);if(!imported)throw Error('Unresolved imported binding');
      const access=imported.imported==='*'?imported.variable:imported.variable+'['+JSON.stringify(imported.imported)+']';
      for(const ref of variable.references){
        if(ref.isWrite())throw Error('Cannot assign an imported module binding');
        const node=ref.identifier,parent=parents.get(node);let replacement=access;
        if(edits.some(([start,end])=>start<=node.start&&end>=node.end))continue;
        if(parent&&parent.type==='Property'&&parent.shorthand&&parent.value===node)replacement=node.name+':'+access;
        else if(parent&&((parent.type==='CallExpression'&&parent.callee===node)||(parent.type==='TaggedTemplateExpression'&&parent.tag===node)))replacement='(0,'+access+')';
        edits.push([node.start,node.end,replacement]);
      }
    }
    // eval strings cannot observe transformed live imported lexicals. Refuse this
    // combination rather than silently returning a stale/synthetic import value.
    if(record.imports.size){
      function rejectEval(node){if(!node||typeof node!=='object')return;if(node.type==='CallExpression'&&node.callee.type==='Identifier'&&node.callee.name==='eval')throw Error('Direct eval with module imports is not supported');for(const key of Object.keys(node)){const v=node[key];if(Array.isArray(v))v.forEach(rejectEval);else if(v&&typeof v==='object')rejectEval(v);}}
      rejectEval(ast);
    }
    const unique=new Map();for(const edit of edits)unique.set(edit[0]+':'+edit[1],edit);
    let transformed=code;for(const [start,end,text] of [...unique.values()].sort((a,b)=>b[0]-a[0]||b[1]-a[1]))transformed=transformed.slice(0,start)+text+transformed.slice(end);
    const definitions=[...localGetters].map(([name,expr])=>JSON.stringify(name)+':()=>('+expr+')').join(',');
    const imports=record.dependencies.map((id,index)=>'const '+prefix+'Dependency'+index+'='+host+'.load('+JSON.stringify(id)+');').join('\n');
    const body='"use strict";\n'+host+'.set({'+definitions+'});\n'+imports+'\n'+transformed+'\n';
    record.factory=new Function(...Object.keys(globals),'return function('+host+'){'+body+'};')(...Object.values(globals));
    for(const id of record.dependencies)getRecord(id);
    return record;
  }
  const root=getRecord('@inline');
  // Export-star name propagation reaches a fixed point before evaluation,
  // including cyclic graphs. Resolution below omits ambiguous star exports.
  for(const record of records.values())for(const name of record.explicit.keys())record.names.add(name);
  for(let pass=0;pass<=records.size;pass++){let changed=false;for(const record of records.values())for(const id of record.stars)for(const name of records.get(id).names)if(name!=='default'&&!record.names.has(name)){record.names.add(name);changed=true;}if(!changed)break;}
  function resolution(record,name,seen=new Set()){
    const visit=record.id+'\0'+name;if(seen.has(visit))return null;seen.add(visit);
    const direct=record.explicit.get(name);
    if(direct){if(direct.kind==='local')return {record,key:direct.local,token:record.id+'\0'+direct.local};if(direct.kind==='namespace')return {namespace:records.get(direct.id).namespace,token:direct.id+'\0*'};return resolution(records.get(direct.id),direct.imported,seen);}
    if(name==='default')return null;
    let match=null;for(const id of record.stars){const value=resolution(records.get(id),name,new Set(seen));if(!value)continue;if(value.ambiguous)return value;if(match&&match.token!==value.token)return {ambiguous:true};match=value;}return match;
  }
  for(const record of records.values()){
    for(const name of record.names){const value=resolution(record,name);if(!value||value.ambiguous)continue;
      Object.defineProperty(record.namespace,name,{enumerable:true,get(){if(value.namespace)return value.namespace;const getter=value.record.getters[value.key];if(!getter)throw ReferenceError('Module binding is not initialized: '+name);return getter();}});}
    Object.defineProperty(record.namespace,Symbol.toStringTag,{value:'Module'});Object.freeze(record.namespace);
    for(const imported of record.imports.values())if(imported.imported!=='*'){const found=resolution(records.get(imported.id),imported.imported);if(!found||found.ambiguous)throw Error('Missing or ambiguous module export: '+imported.imported);}
    for(const descriptor of record.explicit.values())if(descriptor.kind==='indirect'){const found=resolution(records.get(descriptor.id),descriptor.imported);if(!found||found.ambiguous)throw Error('Missing or ambiguous re-export: '+descriptor.imported);}
  }
  function evaluate(record){
    if(record.status==='evaluated'||record.status==='evaluating')return record.namespace;
    record.status='evaluating';record.factory.call(undefined,{set(values){record.getters=values;},load(id){return evaluate(records.get(id));}});record.status='evaluated';return record.namespace;
  }
  return evaluate(root);
})
