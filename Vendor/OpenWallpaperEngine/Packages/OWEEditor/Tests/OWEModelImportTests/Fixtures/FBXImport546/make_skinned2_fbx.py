# Blender: armature "Rig" (root -> arm), a box skinned to root (lower) / arm (upper), two actions
# "wave" (arm rotates 0 -> 60 deg -> 0 over 30 frames) and "walk" (root moves +2 in X over 30 frames),
# plus a static, unskinned mesh "Plinth". Exported with all actions as separate FBX takes.
# Run: blender -b -P make_skinned2_fbx.py -- skinned2.fbx
import bpy, sys, math
out = sys.argv[sys.argv.index("--") + 1]
bpy.ops.wm.read_factory_settings(use_empty=True)
sc = bpy.context.scene; sc.render.fps = 30; sc.frame_start = 0; sc.frame_end = 30
bpy.ops.object.armature_add(enter_editmode=True, location=(0, 0, 0))
arm = bpy.context.object; arm.name = "Rig"
eb = arm.data.edit_bones; root = eb[0]; root.name = "root"; root.head = (0, 0, 0); root.tail = (0, 0, 1)
a = eb.new("arm"); a.head = (0, 0, 1); a.tail = (0, 0, 2); a.parent = root
bpy.ops.object.mode_set(mode="OBJECT")
bpy.ops.mesh.primitive_cube_add(size=0.5, location=(0, 0, 1)); box = bpy.context.object; box.name = "Box"
box.scale = (1, 1, 4); bpy.ops.object.transform_apply(scale=True)
vg_r = box.vertex_groups.new(name="root"); vg_a = box.vertex_groups.new(name="arm")
for v in box.data.vertices:
    (vg_a if v.co.z > 1.0 else vg_r).add([v.index], 1.0, "REPLACE")
mod = box.modifiers.new("Armature", "ARMATURE"); mod.object = arm; box.parent = arm
bpy.ops.mesh.primitive_cube_add(size=1.0, location=(3, 0, -0.5)); pl = bpy.context.object; pl.name = "Plinth"
bpy.context.view_layer.objects.active = arm; bpy.ops.object.mode_set(mode="POSE")
arm.animation_data_create()
def act(name, fn):
    ac = bpy.data.actions.new(name); arm.animation_data.action = ac
    for f in (0, 15, 30): fn(f); 
    ac.use_fake_user = True
    return ac
pa, pr = arm.pose.bones["arm"], arm.pose.bones["root"]
pa.rotation_mode = pr.rotation_mode = "XYZ"
def wave(f):
    pa.rotation_euler = (math.radians(60) * math.sin(math.pi * f / 30), 0, 0); pa.keyframe_insert("rotation_euler", frame=f)
    pr.location = (0, 0, 0); pr.keyframe_insert("location", frame=f)
def walk(f):
    pr.location = (2 * f / 30, 0, 0); pr.keyframe_insert("location", frame=f)
    pa.rotation_euler = (0, 0, 0); pa.keyframe_insert("rotation_euler", frame=f)
w = act("wave", wave); k = act("walk", walk)
bpy.ops.object.mode_set(mode="OBJECT")
bpy.ops.export_scene.fbx(filepath=out, use_selection=False, add_leaf_bones=False, bake_anim=True,
                         bake_anim_use_all_actions=True, bake_anim_use_nla_strips=False)
