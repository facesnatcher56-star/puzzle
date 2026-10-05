# Renders the effect and UI sprites in assets/fx/ with Blender (transparent; effect sprites are white/grey so Godot can tint them).
#   blender -b -P tools/render_fx.py
# 128 px per Blender unit; the camera looks straight down +Z.
import bpy, bmesh, math, os

OUT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "assets", "fx")
os.makedirs(OUT, exist_ok=True)

def reset(w=256, h=256):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    sc = bpy.context.scene
    sc.render.engine = 'CYCLES'
    sc.cycles.device = 'CPU'
    sc.cycles.samples = 48
    sc.cycles.use_denoising = False
    sc.render.film_transparent = True
    sc.render.resolution_x = w
    sc.render.resolution_y = h
    sc.render.image_settings.file_format = 'PNG'
    sc.render.image_settings.color_mode = 'RGBA'
    sc.view_settings.view_transform = 'Standard'
    cam = bpy.data.cameras.new("c"); cam.type = 'ORTHO'; cam.ortho_scale = max(w, h) / 128.0
    co = bpy.data.objects.new("c", cam); sc.collection.objects.link(co)
    co.location = (0, 0, 5); sc.camera = co
    return sc

def render(name):
    bpy.context.scene.render.filepath = os.path.join(OUT, name + ".png")
    bpy.ops.render.render(write_still=True)

def emit(color=(1, 1, 1, 1), strength=1.0):
    m = bpy.data.materials.new("e"); m.use_nodes = True
    nt = m.node_tree; nt.nodes.clear()
    em = nt.nodes.new("ShaderNodeEmission"); em.inputs[0].default_value = color; em.inputs[1].default_value = strength
    out = nt.nodes.new("ShaderNodeOutputMaterial"); nt.links.new(em.outputs[0], out.inputs[0])
    return m

def principled(color, metallic=0.0, roughness=0.4, emission=None, estrength=0.0):
    m = bpy.data.materials.new("p"); m.use_nodes = True
    b = m.node_tree.nodes["Principled BSDF"]
    b.inputs["Base Color"].default_value = color
    b.inputs["Metallic"].default_value = metallic
    b.inputs["Roughness"].default_value = roughness
    if emission is not None:
        b.inputs["Emission Color"].default_value = emission
        b.inputs["Emission Strength"].default_value = estrength
    return m

def lit_world(strength=0.9):
    sc = bpy.context.scene
    w = bpy.data.worlds.new("w"); w.use_nodes = True; sc.world = w
    w.node_tree.nodes["Background"].inputs[1].default_value = strength
    sun = bpy.data.lights.new("s", 'SUN'); sun.energy = 3.0; sun.angle = math.radians(25)
    so = bpy.data.objects.new("s", sun); sc.collection.objects.link(so)
    so.rotation_euler = (math.radians(35), math.radians(-25), math.radians(20))

def falloff_plane(radius, power, strength, ring_at=None, ring_width=0.12):
    """Plane whose emission/alpha falls off smoothly from the centre (or from a ring radius, in UV units)."""
    bpy.ops.mesh.primitive_plane_add(size=radius * 2)
    p = bpy.context.object
    m = bpy.data.materials.new("glow"); m.use_nodes = True
    nt = m.node_tree; nt.nodes.clear()
    tc = nt.nodes.new("ShaderNodeTexCoord")
    vm = nt.nodes.new("ShaderNodeVectorMath"); vm.operation = 'DISTANCE'
    vm.inputs[1].default_value = (0.5, 0.5, 0)
    nt.links.new(tc.outputs["UV"], vm.inputs[0])
    mr = nt.nodes.new("ShaderNodeMapRange"); mr.inputs[1].default_value = 0.0; mr.inputs[2].default_value = 0.5
    mr.inputs[3].default_value = 1.0; mr.inputs[4].default_value = 0.0; mr.clamp = True
    if ring_at is None:
        nt.links.new(vm.outputs["Value"], mr.inputs[0])
    else:
        sub = nt.nodes.new("ShaderNodeMath"); sub.operation = 'SUBTRACT'; sub.inputs[1].default_value = ring_at
        ab = nt.nodes.new("ShaderNodeMath"); ab.operation = 'ABSOLUTE'
        nt.links.new(vm.outputs["Value"], sub.inputs[0]); nt.links.new(sub.outputs[0], ab.inputs[0])
        nt.links.new(ab.outputs[0], mr.inputs[0]); mr.inputs[2].default_value = ring_width
    pw = nt.nodes.new("ShaderNodeMath"); pw.operation = 'POWER'; pw.inputs[1].default_value = power
    nt.links.new(mr.outputs[0], pw.inputs[0])
    em = nt.nodes.new("ShaderNodeEmission"); em.inputs[1].default_value = strength
    tr = nt.nodes.new("ShaderNodeBsdfTransparent")
    mix = nt.nodes.new("ShaderNodeMixShader")
    nt.links.new(pw.outputs[0], mix.inputs[0]); nt.links.new(tr.outputs[0], mix.inputs[1]); nt.links.new(em.outputs[0], mix.inputs[2])
    out = nt.nodes.new("ShaderNodeOutputMaterial"); nt.links.new(mix.outputs[0], out.inputs[0])
    p.data.materials.append(m)
    return p

def rounded_box(w, h, depth, radius, z, mat, rim=0.03):
    """Rounded-rectangle slab (units, not pixels) with a small bevel around its top and bottom edges."""
    radius = min(radius, w / 2 - 0.001, h / 2 - 0.001)
    pts = []
    steps = 12
    for cx, cy, a0 in ((w / 2 - radius, h / 2 - radius, 0), (-w / 2 + radius, h / 2 - radius, 90),
                       (-w / 2 + radius, -h / 2 + radius, 180), (w / 2 - radius, -h / 2 + radius, 270)):
        for i in range(steps + 1):
            a = math.radians(a0 + 90.0 * i / steps)
            pts.append((cx + radius * math.cos(a), cy + radius * math.sin(a), -depth / 2))
    bm = bmesh.new()
    verts = [bm.verts.new(p) for p in pts]
    face = bm.faces.new(verts)
    res = bmesh.ops.extrude_face_region(bm, geom=[face])
    moved = [v for v in res["geom"] if isinstance(v, bmesh.types.BMVert)]
    bmesh.ops.translate(bm, vec=(0, 0, depth), verts=moved)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    mesh = bpy.data.meshes.new("slab"); bm.to_mesh(mesh); bm.free()
    o = bpy.data.objects.new("slab", mesh); bpy.context.scene.collection.objects.link(o)
    o.location = (0, 0, z)
    bv = o.modifiers.new("b", 'BEVEL'); bv.width = rim; bv.segments = 4
    bv.limit_method = 'ANGLE'; bv.angle_limit = math.radians(50)
    mesh.materials.append(mat)
    for poly in mesh.polygons:
        poly.use_smooth = True
    return o

# --- effect sprites -------------------------------------------------------

def make_glow():
    reset(); falloff_plane(1.0, 2.2, 3.0); render("glow")

def spindle(length, thick, rot, strength):
    for sign in (1, -1):
        bpy.ops.mesh.primitive_cone_add(vertices=24, radius1=thick, depth=length)
        o = bpy.context.object
        o.rotation_euler = (0, sign * math.pi / 2, rot)
        o.location = (sign * math.cos(rot) * length / 2, sign * math.sin(rot) * length / 2, 0.1)
        o.data.materials.append(emit((1, 1, 1, 1), strength))

def make_sparkle():
    reset(); falloff_plane(1.0, 3.0, 2.5)
    spindle(0.95, 0.07, 0.0, 6.0); spindle(0.95, 0.07, math.pi / 2, 6.0)
    spindle(0.5, 0.04, math.pi / 4, 3.5); spindle(0.5, 0.04, -math.pi / 4, 3.5)
    render("sparkle")

def make_ring():
    reset(); falloff_plane(1.0, 2.0, 1.2, ring_at=0.39)
    bpy.ops.mesh.primitive_torus_add(major_radius=0.78, minor_radius=0.05, major_segments=96, minor_segments=24, location=(0, 0, 0.1))
    bpy.context.object.data.materials.append(emit((1, 1, 1, 1), 5.0))
    render("ring")

def make_confetti():
    variants = ((35, 20, 25, 0.55, 0.9), (70, -25, -40, 0.6, 0.6), (15, 55, 70, 0.45, 1.0))
    for i, (rx, ry, rz, sx, sy) in enumerate(variants):
        reset(); lit_world(1.2)
        bpy.ops.mesh.primitive_cube_add(size=1)
        c = bpy.context.object
        c.scale = (sx, sy, 0.04)
        c.rotation_euler = (math.radians(rx), math.radians(ry), math.radians(rz))
        bpy.ops.object.transform_apply(scale=True)
        bv = c.modifiers.new("b", 'BEVEL'); bv.width = 0.012; bv.segments = 2
        c.data.materials.append(principled((0.95, 0.95, 0.95, 1), 0.7, 0.3, (1, 1, 1, 1), 0.25))
        render("confetti%d" % i)

def make_rays():
    reset()
    bpy.ops.mesh.primitive_plane_add(size=2.0)
    p = bpy.context.object
    m = bpy.data.materials.new("r"); m.use_nodes = True
    nt = m.node_tree; nt.nodes.clear()
    def node(kind, **kw):
        n = nt.nodes.new(kind)
        for k, v in kw.items():
            setattr(n, k, v)
        return n
    def link(a, b, i=0):
        nt.links.new(a, b.inputs[i])
    tc = node("ShaderNodeTexCoord")
    sep = node("ShaderNodeSeparateXYZ"); link(tc.outputs["UV"], sep)
    cx = node("ShaderNodeMath", operation='SUBTRACT'); cx.inputs[1].default_value = 0.5; link(sep.outputs[0], cx)
    cy = node("ShaderNodeMath", operation='SUBTRACT'); cy.inputs[1].default_value = 0.5; link(sep.outputs[1], cy)
    at = node("ShaderNodeMath", operation='ARCTAN2'); link(cy.outputs[0], at, 0); link(cx.outputs[0], at, 1)
    mu = node("ShaderNodeMath", operation='MULTIPLY'); mu.inputs[1].default_value = 7.0; link(at.outputs[0], mu)
    sn = node("ShaderNodeMath", operation='SINE'); link(mu.outputs[0], sn)
    beams = node("ShaderNodeMapRange"); beams.inputs[1].default_value = 0.1; beams.inputs[2].default_value = 0.9; link(sn.outputs[0], beams)
    d = node("ShaderNodeVectorMath", operation='DISTANCE'); d.inputs[1].default_value = (0.5, 0.5, 0); link(tc.outputs["UV"], d)
    fo = node("ShaderNodeMapRange"); fo.inputs[2].default_value = 0.5; fo.inputs[3].default_value = 1.0; fo.inputs[4].default_value = 0.0; link(d.outputs["Value"], fo)
    fp = node("ShaderNodeMath", operation='POWER'); fp.inputs[1].default_value = 1.4; link(fo.outputs[0], fp)
    mul = node("ShaderNodeMath", operation='MULTIPLY'); link(beams.outputs[0], mul, 0); link(fp.outputs[0], mul, 1)
    em = node("ShaderNodeEmission"); em.inputs[1].default_value = 2.0
    tr = node("ShaderNodeBsdfTransparent"); mix = node("ShaderNodeMixShader")
    link(mul.outputs[0], mix, 0); link(tr.outputs[0], mix, 1); link(em.outputs[0], mix, 2)
    out = node("ShaderNodeOutputMaterial"); link(mix.outputs[0], out)
    p.data.materials.append(m)
    render("rays")

def make_gem():
    reset(128, 128); lit_world(0.9)
    gold = principled((1.0, 0.8, 0.3, 1), 0.9, 0.12, (1.0, 0.7, 0.2, 1), 0.6)
    pivot = bpy.data.objects.new("pivot", None); bpy.context.scene.collection.objects.link(pivot)
    for flip in (False, True):
        bpy.ops.mesh.primitive_cone_add(vertices=8, radius1=0.62, radius2=0.0, depth=0.8)
        o = bpy.context.object
        o.location = (0, 0, -0.4 if flip else 0.4)
        o.rotation_euler = (math.pi, 0, 0) if flip else (0, 0, 0)
        o.data.materials.append(gold)
        for poly in o.data.polygons:
            poly.use_smooth = False
        o.parent = pivot
    pivot.rotation_euler = (math.radians(-65), 0, math.radians(22))
    pivot.scale = (0.72, 0.72, 0.72)
    render("gem")

# --- UI sprites -----------------------------------------------------------

def panel(name, w, h, radius, rim_color, fill_color, rim=0.1, inset=False):
    """A bevelled panel seen from above: a metallic rim around a face that is recessed (inset) or raised."""
    reset(w, h); lit_world(0.5)
    uw, uh = w / 128.0, h / 128.0
    rounded_box(uw, uh, 0.14, radius, 0.0, principled(rim_color, 0.85, 0.28), rim=0.035)
    rounded_box(uw - rim * 2, uh - rim * 2, 0.10, max(radius - rim, 0.02), 0.026 if inset else 0.06, principled(fill_color, 0.1, 0.45), rim=0.02)
    render(name)

def make_ui():
    gold = (1.0, 0.72, 0.28, 1); teal = (0.35, 0.78, 0.7, 1); slate = (0.5, 0.58, 0.62, 1)
    panel("ui_panel", 192, 192, 0.32, gold, (0.06, 0.1, 0.13, 1), rim=0.1, inset=True)
    panel("ui_button", 96, 64, 0.11, slate, (0.12, 0.2, 0.25, 1), rim=0.05)
    panel("ui_button_hover", 96, 64, 0.11, gold, (0.17, 0.3, 0.37, 1), rim=0.05)
    panel("ui_button_pressed", 96, 64, 0.11, gold, (0.08, 0.14, 0.18, 1), rim=0.05, inset=True)
    panel("ui_slot", 96, 96, 0.14, teal, (0.06, 0.11, 0.13, 1), rim=0.05, inset=True)
    panel("ui_slot_hot", 96, 96, 0.14, gold, (0.14, 0.2, 0.2, 1), rim=0.06, inset=True)
    reset(128, 32); lit_world(0.7)
    rounded_box(1.0, 0.25, 0.14, 0.12, 0.0, principled((1, 1, 1, 1), 0.0, 0.2, (1, 1, 1, 1), 0.35), rim=0.05)
    render("ui_bar_fill")

if __name__ == "__main__":
    for step in (make_glow, make_sparkle, make_ring, make_confetti, make_rays, make_gem, make_ui):
        step()
