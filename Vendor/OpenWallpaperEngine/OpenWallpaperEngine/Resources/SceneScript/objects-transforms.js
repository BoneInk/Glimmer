'use strict';
// SceneScript object model, part 5 of 6: the `ILayer` members that change a layer's place in the
// transform hierarchy or its orientation (`setParent`, `lookAt`, `lookAtYaw`, `rotateObjectSpace`)
// and `IEffectLayer.transformAttachmentToTexture`. Orientation writes go through the layer's own
// `angles` (and `origin`, `scale`), so they read back at once and reach the renderer like any
// member write; a new parent reaches it as a command.
//
// Matrices are WE's Mat4 memory: column-major, translation in 12..14, column i is WE's row i (the
// object's local axis i in its parent's space; SceneWorldMatrix).
(function (global) {
    const rt = global.__rt;
    const objects = rt.objects;
    const OP = objects.OP;
    const table = objects.table;
    const P = objects.Layer.prototype;
    const RAD = Math.PI / 180;
    const EPSILON = 1e-12;

    function worldOf(layer) {
        const t = layer._t, base = layer._base + table.layout.worldMatrix;
        const m = new Array(16);
        for (let i = 0; i < 16; i++) m[i] = t[base + i];
        return m;
    }

    const IDENTITY = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1];

    // The inverse of an affine matrix; undefined when it collapses an axis.
    function inverseAffine(m) {
        const a = m[0], b = m[4], c = m[8], d = m[1], e = m[5], f = m[9], g = m[2], h = m[6], k = m[10];
        const A = e * k - f * h, B = -(d * k - f * g), C = d * h - e * g;
        const det = a * A + b * B + c * C;
        if (!isFinite(det) || Math.abs(det) < EPSILON) return undefined;
        const s = 1 / det;
        // Rows of the inverse linear part.
        const r = [[A * s, -(b * k - c * h) * s, (b * f - c * e) * s],
            [B * s, (a * k - c * g) * s, -(a * f - c * d) * s],
            [C * s, -(a * h - b * g) * s, (a * e - b * d) * s]];
        const t = [m[12], m[13], m[14]];
        const out = new Array(16);
        for (let col = 0; col < 3; col++) {
            for (let row = 0; row < 3; row++) out[col * 4 + row] = r[row][col];
            out[col * 4 + 3] = 0;
        }
        for (let row = 0; row < 3; row++) out[12 + row] = -(r[row][0] * t[0] + r[row][1] * t[1] + r[row][2] * t[2]);
        out[15] = 1;
        return out;
    }

    // MARK: rotation rows (SceneWorldMatrix.rows / .angles)

    // 0x1401dd630: the rows of R = Rz·Ry·Rx of `degrees`, each the object's local axis in its
    // parent's space.
    function rows(degrees) {
        const x = degrees[0] * RAD, y = degrees[1] * RAD, z = degrees[2] * RAD;
        const cx = Math.cos(x), sx = Math.sin(x), cy = Math.cos(y), sy = Math.sin(y), cz = Math.cos(z), sz = Math.sin(z);
        return [[cy * cz, cy * sz, -sy], [sx * sy * cz - cx * sz, sx * sy * sz + cx * cz, sx * cy],
            [cx * sy * cz + sx * sz, cx * sy * sz - sx * cz, cx * cy]];
    }

    // WE's extraction (0x1401f31f7–0x1401f3306): the angles, in degrees, whose rows are `r`.
    function anglesOf(r) {
        const z = Math.atan2(r[0][1], r[0][0]);
        const y = Math.atan2(-r[0][2], Math.sqrt(r[1][2] * r[1][2] + r[2][2] * r[2][2]));
        const sz = Math.sin(z), cz = Math.cos(z);
        const x = Math.atan2(r[2][0] * sz - r[2][1] * cz, r[1][1] * cz - r[1][0] * sz);
        return [x / RAD, y / RAD, z / RAD];
    }

    function vector(value) {
        if (!value || typeof value !== 'object') return undefined;
        const v = [value.x, value.y, value.z];
        for (let i = 0; i < 3; i++) if (typeof v[i] !== 'number' || !isFinite(v[i])) return undefined;
        return v;
    }

    function current(layer, name) {
        const v = layer[name];
        return [v.x, v.y, v.z];
    }

    function setAngles(layer, degrees) { layer.angles = objects.vec3(degrees[0], degrees[1], degrees[2]); }

    function cross(a, b) { return [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]]; }
    function dot(a, b) { return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]; }
    function normalized(v) {
        const length = Math.sqrt(dot(v, v));
        return length > EPSILON && isFinite(length) ? [v[0] / length, v[1] / length, v[2] / length] : undefined;
    }

    // MARK: orientation

    // `lookAt(center, up?)` (0x1401dfc00; `lookAtYaw` 0x1401dfe30): the basis of `lookAtRH`
    // (0x14019d920: f = normalize(target − eye), s = normalize(f × up), u = s × f) as the rows
    // (s, u, −f), extracted as WE writes a camera layer's angles back from its path (0x1401f31f2;
    // SceneWorldMatrix.lookAtAngles). The eye is the layer's `origin` (+0x128), so `center` is in
    // its parent's space. WE aims a camera (object type 8, vtable +0x60) at `center`, so its −z
    // points there; any other object at the mirror image eye − (center − eye) (0x1401dfcc5), so
    // its +z, the side an image shows, points at `center`. A centre on the eye, or an up along
    // the view, leaves the angles as they are.
    function lookAt(layer, center, up, yawOnly) {
        const c = vector(center);
        if (c === undefined || layer._dead) return;
        const u = up === undefined || up === null ? [0, 1, 0] : vector(up);
        if (u === undefined) return;
        const eye = current(layer, 'origin');
        let direction = [c[0] - eye[0], c[1] - eye[1], c[2] - eye[2]];
        if (yawOnly) {
            // "only adjust the heading and up axis but won't let the layer face down or up": the
            // direction without its part along `up`, so the layer stays upright.
            const axis = normalized(u);
            if (axis === undefined) return;
            const along = dot(direction, axis);
            direction = [direction[0] - along * axis[0], direction[1] - along * axis[1], direction[2] - along * axis[2]];
        }
        if (layer._record.kind !== 'camera') direction = [-direction[0], -direction[1], -direction[2]];
        const f = normalized(direction);
        if (f === undefined) return;
        const s = normalized(cross(f, u));
        if (s === undefined) return;
        setAngles(layer, anglesOf([s, cross(s, f), [-f[0], -f[1], -f[2]]]));
    }

    objects.defineMethod(P, 'lookAt', function (center, up) { lookAt(this, center, up, false); });
    objects.defineMethod(P, 'lookAtYaw', function (center, up) { lookAt(this, center, up, true); });

    // "Rotate the layer around its current object axes": the rotation of `angles` applied in the
    // layer's own space before its current one (R' = R · R(angles)), so the rows become
    // row'ᵢ = Σⱼ R(angles)ᵢⱼ · rowⱼ.
    objects.defineMethod(P, 'rotateObjectSpace', function (angles) {
        const delta = vector(angles);
        if (delta === undefined || this._dead) return;
        const c = rows(current(this, 'angles')), d = rows(delta);
        const out = [0, 1, 2].map(function (i) {
            return [0, 1, 2].map(function (k) { return d[i][0] * c[0][k] + d[i][1] * c[1][k] + d[i][2] * c[2][k]; });
        });
        setAngles(this, anglesOf(out));
    });

    // MARK: parenting

    // A layer from `String|Number|ILayer`: the layer itself, a name (then an id as text), or a
    // number as a layer id [I: scene.json's `parent` is an id].
    function layerFrom(value) {
        if (value instanceof objects.Layer) return value._dead ? null : value;
        if (typeof value === 'number') {
            const layer = objects.byID.get(value);
            return layer === undefined || layer._dead ? null : layer;
        }
        if (typeof value === 'string') {
            const order = objects.order;
            return order.find(function (layer) { return layer._name === value; })
                || order.find(function (layer) { return String(layer._id) === value; }) || null;
        }
        return null;
    }

    // The attachment's name on `parent`'s rig: a name as given, an index looked up; '' for none.
    function attachmentName(parent, attachment) {
        if (typeof attachment === 'string') return attachment;
        if (typeof attachment !== 'number') return '';
        const rig = objects.rigOf(parent);
        const entry = rig ? rig.attachments[Math.floor(attachment)] : undefined;
        return entry === undefined ? '' : String(entry.name);
    }

    // `local` as origin, scale and angles (degrees). A planar matrix (the 2D path's world: no z
    // axis part) gives only the x and y of origin and scale and the z angle; `layer` keeps the rest.
    function writeLocal(layer, local, planar) {
        const columns = [0, 1, 2].map(function (i) { return [local[i * 4], local[i * 4 + 1], local[i * 4 + 2]]; });
        const scale = columns.map(function (column) { return Math.sqrt(dot(column, column)); });
        if (dot(cross(columns[0], columns[1]), columns[2]) < 0) scale[0] = -scale[0];
        if (scale[0] === 0 || scale[1] === 0 || scale[2] === 0) return;
        const r = columns.map(function (column, i) { return [column[0] / scale[i], column[1] / scale[i], column[2] / scale[i]]; });
        let angles = anglesOf(r);
        let origin = [local[12], local[13], local[14]];
        if (planar) {
            const ownOrigin = current(layer, 'origin'), ownScale = current(layer, 'scale'), ownAngles = current(layer, 'angles');
            origin = [origin[0], origin[1], ownOrigin[2]];
            scale[2] = ownScale[2];
            angles = [ownAngles[0], ownAngles[1], Math.atan2(r[0][1], r[0][0]) / RAD];
        }
        layer.origin = objects.vec3(origin[0], origin[1], origin[2]);
        layer.scale = objects.vec3(scale[0], scale[1], scale[2]);
        setAngles(layer, angles);
    }

    function isPlanar(m) {
        return m[2] === 0 && m[6] === 0 && m[8] === 0 && m[9] === 0 && m[10] === 1 && m[14] === 0;
    }

    // setParent(parent, adjustTransforms?) and setParent(parent, attachment, adjustTransform?).
    // "Pass undefined for the parent to remove the parent." A parent that names no live layer, or
    // one that would make the layer its own ancestor, changes nothing [I]. With adjustTransforms
    // the layer's own transform becomes its world one relative to the new parent's space (its
    // world, then the attachment's when given), so it stays in place.
    objects.defineMethod(P, 'setParent', function (parent, attachmentOrAdjust, adjust) {
        if (this._dead) return;
        let attachment, keepWorld;
        if (typeof attachmentOrAdjust === 'string' || typeof attachmentOrAdjust === 'number') {
            attachment = attachmentOrAdjust;
            keepWorld = adjust;
        } else {
            keepWorld = attachmentOrAdjust;
        }
        let target = null;
        if (parent !== undefined && parent !== null) {
            target = layerFrom(parent);
            if (target === null) return;
            // Bounded, so a cycle an authored scene already has ends the walk.
            let ancestor = target;
            for (let steps = objects.order.length; ancestor !== undefined && steps >= 0; steps--) {
                if (ancestor === this) return;
                ancestor = ancestor.getParent();
            }
        }
        const name = target === null ? '' : attachmentName(target, attachment);
        if (keepWorld) {
            let space = IDENTITY;
            if (target !== null) {
                space = (name !== '' ? objects.attachmentWorld(target, name) : undefined) || worldOf(target);
            }
            const inverse = inverseAffine(space);
            const world = worldOf(this);
            if (inverse !== undefined) writeLocal(this, objects.multiplyMat4(inverse, world), isPlanar(space) && isPlanar(world));
        }
        this._record.parentID = target === null ? null : target._id;
        objects.push(OP.setParent, this._slot, target === null ? undefined : [target._slot], name === '' ? undefined : [name]);
    });

    // MARK: texture space

    // Where a quad sits relative to its origin (SceneAlignment.centerOffset): `left` puts its
    // left edge on the origin, `top` its top edge; in unscaled local units.
    function centerOffset(alignment, size) {
        const text = String(alignment || '').toLowerCase();
        let x = 0, y = 0;
        if (text.indexOf('left') >= 0) x = size[0] / 2; else if (text.indexOf('right') >= 0) x = -size[0] / 2;
        if (text.indexOf('top') >= 0) y = -size[1] / 2; else if (text.indexOf('bottom') >= 0) y = size[1] / 2;
        return [x, y];
    }

    // transformAttachmentToTexture(attachmentLayer, attachmentName): "a 2D transformation matrix
    // in texture space of this layer for an attachment on any layer of the scene". The attachment's
    // world matrix in this layer's local space, projected to its quad's texture coordinates: u
    // from 0 at the left edge to 1 at the right, v from 0 at the top to 1 at the bottom [I: WE's
    // texture space, as its shaders sample]. Column-major, translation in m[6], m[7]. Identity
    // when the layer, the attachment or this layer's size is missing, or its world is singular.
    objects.defineMethod(P, 'transformAttachmentToTexture', function (attachmentLayer, name) {
        const result = objects.mat3();
        const target = layerFrom(attachmentLayer);
        const attachment = target === null || this._dead ? undefined : objects.attachmentWorld(target, name);
        const inverse = attachment === undefined ? undefined : inverseAffine(worldOf(this));
        const size = [this.size.x, this.size.y];
        if (inverse === undefined || !(size[0] > 0) || !(size[1] > 0)) return result;
        const local = objects.multiplyMat4(inverse, attachment);
        const center = centerOffset(this._strings.alignment, size);
        // texture = T · local2D, T: x → (x − cx)/w + 1/2, y → 1/2 − (y − cy)/h.
        const sx = 1 / size[0], sy = -1 / size[1];
        const tx = 0.5 - center[0] * sx, ty = 0.5 - center[1] * sy;
        const m = [sx * local[0], sy * local[1], 0,
            sx * local[4], sy * local[5], 0,
            sx * local[12] + tx, sy * local[13] + ty, 1];
        for (let i = 0; i < 9; i++) result.m[i] = m[i];
        return result;
    });
})(this);
