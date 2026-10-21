import Foundation

/// SceneScript's API as declarations, the source of the code editor's autocomplete
/// (`SceneScriptAPICatalog`). Written from the API WE documents (docs.wallpaperengine.io's
/// SceneScript reference, summarised in docs/scenescript-plan.md §1) and the object model's member
/// names the repository keeps from WE's typings (`Tests/Fixtures/SceneScript/object-model-members.json`,
/// lib.sceneScript.d.ts 2.8), in a TypeScript subset the catalog reads:
///
/// - `interface Name extends A, B { … }` with `name: Type;`, `readonly name: Type;`, `name?: Type;`
///   and `name(parameters): Type;` members, each optionally after a one-line `/** doc */`;
/// - `type Name = A & B;` (a layer has every kind's members, as WE's `ILayer` union does);
/// - `declare const name: Type;` for globals, `declare class Name: Type;` for constructors,
///   `declare module Name: Type;` for importable modules.
public enum SceneScriptTypings {
    public static let source = #"""
    /** Members every scene object has. */
    interface IObject {
        /** The timeline animation bound to this property, or the named one. */
        getAnimation(name?: String): IAnimation;
    }

    /** A layer of the scene: image, text, sound, particle system, model, light or camera. */
    interface ILayer extends IObject {
        /** Position in scene units. */
        origin: Vec3;
        /** Rotation in degrees. */
        angles: Vec3;
        scale: Vec3;
        parallaxDepth: Vec2;
        readonly name: String;
        /** Shown or hidden (image layers and particle systems). */
        visible: Boolean;
        getTransformMatrix(): Mat4;
        rotateObjectSpace(angles: Vec3): void;
        lookAt(center: Vec3, up?: Vec3): void;
        lookAtYaw(center: Vec3, up?: Vec3): void;
        setParent(parent: ILayer, attachment?: Number, adjustTransforms?: Boolean): void;
        getParent(): AnyLayer;
        getChildren(): AnyLayer[];
        getAttachmentIndex(name: String): Number;
        getAttachmentMatrix(index: Number): Mat4;
        getAttachmentOrigin(index: Number): Vec3;
        getAttachmentAngles(index: Number): Vec3;
    }

    /** A layer that can have effects (image and text layers). */
    interface IEffectLayer {
        getEffect(nameOrIndex: String | Number): IEffect;
        getEffectCount(): Number;
        /** The layer's size in pixels. */
        readonly size: Vec2;
        perspective: Boolean;
        solid: Boolean;
        transformAttachmentToTexture(attachment: Vec3): Vec2;
    }

    /** An image layer: its colour, alpha, texture and video, puppet bones and animation layers. */
    interface IImageLayer {
        alpha: Number;
        /** Normalized colour, 0…1 per channel. */
        color: Vec3;
        alignment: String;
        getTextureAnimation(): ITextureAnimation;
        getVideoTexture(): IVideoTexture;
        getAnimationLayerCount(): Number;
        getAnimationLayer(nameOrIndex: String | Number): IAnimationLayer;
        createAnimationLayer(animation: String | Number): IAnimationLayer;
        destroyAnimationLayer(layer: IAnimationLayer | Number): Boolean;
        playSingleAnimation(animation: String | Number, config?: Object): IAnimationLayer;
        getBoneCount(): Number;
        getBoneIndex(name: String): Number;
        getBoneParentIndex(index: Number): Number;
        getBoneTransform(index: Number): Mat4;
        setBoneTransform(index: Number, transform: Mat4): void;
        getLocalBoneTransform(index: Number): Mat4;
        setLocalBoneTransform(index: Number, transform: Mat4): void;
        getLocalBoneAngles(index: Number): Vec3;
        setLocalBoneAngles(index: Number, angles: Vec3): void;
        getLocalBoneOrigin(index: Number): Vec3;
        setLocalBoneOrigin(index: Number, origin: Vec3): void;
        applyBonePhysicsImpulse(index: Number, directionalImpulse: Vec3, angularImpulse?: Vec3): void;
        resetBonePhysicsSimulation(index?: Number): void;
        getBlendShapeIndex(name: String): Number;
        getBlendShapeWeight(index: Number): Number;
        setBlendShapeWeight(index: Number, weight: Number): void;
    }

    /** A text layer. */
    interface ITextLayer {
        text: String;
        color: Vec3;
        alpha: Number;
        font: String;
        pointsize: Number;
        padding: Number;
        opaquebackground: Boolean;
        backgroundcolor: Vec3;
        horizontalalign: String;
        verticalalign: String;
        anchor: String;
        limitrows: Boolean;
        maxrows: Number;
        limitwidth: Boolean;
        maxwidth: Number;
    }

    /** A sound layer. */
    interface ISoundLayer {
        volume: Number;
        play(): void;
        stop(): void;
        pause(): void;
        isPlaying(): Boolean;
    }

    /** A particle system. */
    interface IParticleSystem {
        /** The instance overrides of this system. */
        readonly instance: IParticleSystemInstance;
        play(): void;
        pause(): void;
        stop(): void;
        isPlaying(): Boolean;
        emitParticles(count?: Number): void;
    }

    /** A particle system's instance overrides (multipliers of its definition). */
    interface IParticleSystemInstance {
        alpha: Number;
        size: Number;
        count: Number;
        speed: Number;
        lifetime: Number;
        rate: Number;
        colorn: Number;
        controlpoint0: Vec3;
        controlpoint1: Vec3;
        controlpoint2: Vec3;
        controlpoint3: Vec3;
        controlpoint4: Vec3;
        controlpoint5: Vec3;
        controlpoint6: Vec3;
        controlpoint7: Vec3;
    }

    /** A 3D model layer. */
    interface IModelLayer {
        perspective: Boolean;
        rootmotion: Boolean;
        getAnimationLayerCount(): Number;
        getAnimationLayer(nameOrIndex: String | Number): IAnimationLayer;
        createAnimationLayer(animation: String | Number): IAnimationLayer;
        destroyAnimationLayer(layer: IAnimationLayer | Number): Boolean;
        playSingleAnimation(animation: String | Number, config?: Object): IAnimationLayer;
    }

    /** A camera layer. */
    interface ICamera {
        fov: Number;
        zoom: Number;
    }

    /** Any layer: members that don't apply to its kind do nothing. */
    type AnyLayer = ILayer & IEffectLayer & IImageLayer & ITextLayer & ISoundLayer & IParticleSystem & IModelLayer & ICamera;

    /** An effect of a layer. */
    interface IEffect extends IObject {
        visible: Boolean;
        readonly name: String;
        getMaterial(index: Number): IMaterial;
        getMaterialCount(): Number;
        /** Sets a shader constant on every material of the effect that has it. */
        setMaterialProperty(name: String, value: Number | Vec2 | Vec3 | Vec4): void;
        executeMaterialFunction(name: String): void;
    }

    /** A material of an effect; its shader constants are its members by name. */
    interface IMaterial {
    }

    /** A timeline animation of a property. */
    interface IAnimation {
        readonly fps: Number;
        readonly frameCount: Number;
        readonly duration: Number;
        readonly name: String;
        rate: Number;
        play(): void;
        pause(): void;
        stop(): void;
        isPlaying(): Boolean;
        getFrame(): Number;
        setFrame(frame: Number): void;
    }

    /** A puppet or model animation layer. */
    interface IAnimationLayer extends IAnimation {
        blend: Number;
        visible: Boolean;
        addEndedCallback(callback: Function): void;
    }

    /** A sprite sheet or GIF texture's animation. */
    interface ITextureAnimation {
        readonly frameCount: Number;
        readonly duration: Number;
        rate: Number;
        play(): void;
        pause(): void;
        stop(): void;
        isPlaying(): Boolean;
        getFrame(): Number;
        setFrame(frame: Number): void;
        join(other: ITextureAnimation): void;
    }

    /** A video texture. */
    interface IVideoTexture {
        readonly duration: Number;
        rate: Number;
        loop: Boolean;
        play(): void;
        pause(): void;
        stop(): void;
        isPlaying(): Boolean;
        getCurrentTime(): Number;
        setCurrentTime(time: Number): void;
        addEndedCallback(callback: Function): void;
    }

    /** Mesh data a script builds for a model layer. */
    interface IModelData {
        readonly POSITION: Number;
        readonly NORMAL: Number;
        readonly TANGENT_SIGNED: Number;
        readonly UV: Number;
        readonly COLOR: Number;
        applyData(): void;
        replaceData(attribute: Number, data: Float32Array): void;
    }

    /** The scene: its layers, camera and settings. */
    interface IScene extends IObject {
        getLayer(nameOrIndexOrId: String | Number): AnyLayer;
        getLayerByID(id: Number): AnyLayer;
        getLayerCount(): Number;
        enumerateLayers(): AnyLayer[];
        getLayerIndex(layer: ILayer | String): Number;
        getInitialLayerConfig(layer: ILayer): Object;
        /** Creates a layer from an asset path, a handle, a configuration or model data. */
        createLayer(configuration: String | Object | IAssetHandle | IModelData): AnyLayer;
        /** Removes the layer after every script of this frame updated. */
        destroyLayer(layer: ILayer): void;
        sortLayer(layer: ILayer, index: Number): void;
        createModelData(configuration: Object): IModelData;
        destroyModelData(data: IModelData): void;
        getCameraTransforms(): ICameraTransforms;
        setCameraTransforms(transforms: ICameraTransforms): void;
        fov: Number;
        nearz: Number;
        farz: Number;
        bloom: Boolean;
        bloomstrength: Number;
        bloomthreshold: Number;
        clearenabled: Boolean;
        clearcolor: Vec3;
        ambientcolor: Vec3;
        skylightcolor: Vec3;
        camerafade: Boolean;
        camerashake: Boolean;
        camerashakespeed: Number;
        camerashakeamplitude: Number;
        camerashakeroughness: Number;
        cameraparallax: Boolean;
        cameraparallaxamount: Number;
        cameraparallaxdelay: Number;
        cameraparallaxmouseinfluence: Number;
    }

    interface ICameraTransforms {
        eye: Vec3;
        center: Vec3;
        up: Vec3;
        zoom: Number;
    }

    /** A registered asset. */
    interface IAssetHandle {
    }

    /** The audio spectrum, refreshed every frame. */
    interface AudioBuffers {
        readonly left: Float32Array;
        readonly right: Float32Array;
        readonly average: Float32Array;
    }

    /** The engine: time, screen, user properties and services. */
    interface IEngine {
        /** Seconds since the last frame. */
        readonly frametime: Number;
        /** Seconds since the wallpaper started. */
        readonly runtime: Number;
        /** The time of day, 0…1. */
        readonly timeOfDay: Number;
        readonly screenResolution: Vec2;
        readonly canvasSize: Vec2;
        /** The user properties: colours as Vec3, everything else its value. */
        readonly userProperties: Object;
        readonly AUDIO_RESOLUTION_16: Number;
        readonly AUDIO_RESOLUTION_32: Number;
        readonly AUDIO_RESOLUTION_64: Number;
        /** Audio spectrum buffers of 16, 32 or 64 bands; only at global scope. */
        registerAudioBuffers(resolution: Number): AudioBuffers;
        /** Registers an asset to create layers from; only at global scope. */
        registerAsset(file: String, precache?: Boolean): IAssetHandle;
        /** Calls back once after the delay; returns a function that cancels it. */
        setTimeout(callback: Function, milliseconds: Number): Function;
        /** Calls back repeatedly; returns a function that stops it. */
        setInterval(callback: Function, milliseconds: Number): Function;
        /** Runs a user shortcut property's command; only inside cursor callbacks. */
        openUserShortcut(name: String): Boolean;
        isRunningInEditor(): Boolean;
        isPortrait(): Boolean;
        isLandscape(): Boolean;
        isDesktopDevice(): Boolean;
        isMobileDevice(): Boolean;
        isWallpaper(): Boolean;
        isScreensaver(): Boolean;
    }

    /** The cursor. */
    interface IInput {
        /** The cursor in scene units. */
        readonly cursorWorldPosition: Vec3;
        /** The cursor in screen pixels. */
        readonly cursorScreenPosition: Vec2;
        readonly cursorLeftDown: Boolean;
    }

    /** The log: the editor's console. */
    interface IConsole {
        log(...values: any): void;
        error(...values: any): void;
    }

    /** Values kept between runs, per screen ('screen', the default) or for every screen ('global'). */
    interface ILocalStorage {
        readonly LOCATION_GLOBAL: String;
        readonly LOCATION_SCREEN: String;
        set(key: String, value: any, location?: String): void;
        get(key: String, location?: String): any;
        delete(key: String, location?: String): Boolean;
        clear(location?: String): void;
    }

    /** A cursor event of the object the script belongs to. */
    interface CursorEvent {
        readonly worldPosition: Vec3;
        readonly localPosition: Vec3;
        /** The puppet hit box's name, if any. */
        readonly hitBox: String;
    }

    /** Media integration: the track playing in the user's player. */
    interface MediaPropertiesEvent {
        readonly title: String;
        readonly artist: String;
        readonly subTitle: String;
        readonly albumTitle: String;
        readonly albumArtist: String;
        readonly genres: String;
        readonly contentType: String;
    }

    interface MediaThumbnailEvent {
        readonly hasThumbnail: Boolean;
        readonly primaryColor: Vec3;
        readonly secondaryColor: Vec3;
        readonly tertiaryColor: Vec3;
        readonly textColor: Vec3;
        readonly highContrastColor: Vec3;
    }

    interface MediaPlaybackEvent {
        /** PLAYBACK_STOPPED, PLAYBACK_PLAYING or PLAYBACK_PAUSED. */
        readonly state: Number;
    }

    interface MediaStatusEvent {
        readonly enabled: Boolean;
    }

    interface MediaTimelineEvent {
        readonly position: Number;
        readonly duration: Number;
    }

    interface MediaPlaybackEventClass {
        readonly PLAYBACK_STOPPED: Number;
        readonly PLAYBACK_PLAYING: Number;
        readonly PLAYBACK_PAUSED: Number;
    }

    /** The callbacks a script exports. */
    interface SceneScriptCallbacks {
        /** Once, when the object was created; returns the property's first value. */
        init(value: any): any;
        /** Every frame; returns the property's new value. */
        update(value: any): any;
        /** Before the object is destroyed. */
        destroy(): void;
        /** When the screen's resolution changes (not at start). */
        resizeScreen(size: Vec2): void;
        /** At load, then with only the changed user properties. */
        applyUserProperties(changed: Object): void;
        /** At load, then with only the changed general settings. */
        applyGeneralSettings(changed: Object): void;
        cursorEnter(event: CursorEvent): void;
        cursorLeave(event: CursorEvent): void;
        cursorMove(event: CursorEvent): void;
        cursorDown(event: CursorEvent): void;
        cursorUp(event: CursorEvent): void;
        cursorClick(event: CursorEvent): void;
        mediaStatusChanged(event: MediaStatusEvent): void;
        mediaPlaybackChanged(event: MediaPlaybackEvent): void;
        mediaPropertiesChanged(event: MediaPropertiesEvent): void;
        mediaThumbnailChanged(event: MediaThumbnailEvent): void;
        mediaTimelineChanged(event: MediaTimelineEvent): void;
        animationEvent(event: Object, value: any): any;
    }

    /** The properties a script declares, shown in the editor and stored with the script. */
    interface ScriptPropertiesBuilder {
        addSlider(options: Object): ScriptPropertiesBuilder;
        addCheckbox(options: Object): ScriptPropertiesBuilder;
        addText(options: Object): ScriptPropertiesBuilder;
        addCombo(options: Object): ScriptPropertiesBuilder;
        addColor(options: Object): ScriptPropertiesBuilder;
        finish(): Object;
    }

    interface Vec2 {
        x: Number;
        y: Number;
        length(): Number;
        lengthSqr(): Number;
        distance(other: Vec2): Number;
        distanceSqr(other: Vec2): Number;
        normalize(): Vec2;
        copy(): Vec2;
        equals(other: Vec2): Boolean;
        isFinite(): Boolean;
        negate(): Vec2;
        add(other: Vec2 | Number): Vec2;
        subtract(other: Vec2 | Number): Vec2;
        multiply(other: Vec2 | Number): Vec2;
        divide(other: Vec2 | Number): Vec2;
        dot(other: Vec2): Number;
        reflect(normal: Vec2): Vec2;
        perpendicular(): Vec2;
        project(other: Vec2): Vec2;
        angle(): Number;
        angleBetween(other: Vec2): Number;
        rotate(angle: Number): Vec2;
        mix(other: Vec2, amount: Number | Vec2): Vec2;
        min(other: Vec2 | Number): Vec2;
        max(other: Vec2 | Number): Vec2;
        clamp(min: Vec2 | Number, max: Vec2 | Number): Vec2;
        abs(): Vec2;
        sign(): Vec2;
        round(): Vec2;
        floor(): Vec2;
        ceil(): Vec2;
        fract(): Vec2;
        mod(other: Vec2 | Number): Vec2;
        step(edge: Vec2 | Number): Vec2;
        smoothStep(min: Vec2 | Number, max: Vec2 | Number): Vec2;
        toString(): String;
    }

    interface Vec3 {
        x: Number;
        y: Number;
        z: Number;
        length(): Number;
        lengthSqr(): Number;
        distance(other: Vec3): Number;
        distanceSqr(other: Vec3): Number;
        normalize(): Vec3;
        copy(): Vec3;
        equals(other: Vec3): Boolean;
        isFinite(): Boolean;
        negate(): Vec3;
        add(other: Vec3 | Number): Vec3;
        subtract(other: Vec3 | Number): Vec3;
        multiply(other: Vec3 | Number): Vec3;
        divide(other: Vec3 | Number): Vec3;
        dot(other: Vec3): Number;
        cross(other: Vec3): Vec3;
        reflect(normal: Vec3): Vec3;
        refract(normal: Vec3, eta: Number): Vec3;
        project(other: Vec3): Vec3;
        angleBetween(other: Vec3): Number;
        toSpherical(): Vec3;
        mix(other: Vec3, amount: Number | Vec3): Vec3;
        min(other: Vec3 | Number): Vec3;
        max(other: Vec3 | Number): Vec3;
        clamp(min: Vec3 | Number, max: Vec3 | Number): Vec3;
        abs(): Vec3;
        sign(): Vec3;
        round(): Vec3;
        floor(): Vec3;
        ceil(): Vec3;
        fract(): Vec3;
        mod(other: Vec3 | Number): Vec3;
        step(edge: Vec3 | Number): Vec3;
        smoothStep(min: Vec3 | Number, max: Vec3 | Number): Vec3;
        toString(): String;
    }

    interface Vec4 {
        x: Number;
        y: Number;
        z: Number;
        w: Number;
        length(): Number;
        lengthSqr(): Number;
        distance(other: Vec4): Number;
        normalize(): Vec4;
        copy(): Vec4;
        equals(other: Vec4): Boolean;
        add(other: Vec4 | Number): Vec4;
        subtract(other: Vec4 | Number): Vec4;
        multiply(other: Vec4 | Number): Vec4;
        divide(other: Vec4 | Number): Vec4;
        dot(other: Vec4): Number;
        mix(other: Vec4, amount: Number | Vec4): Vec4;
        abs(): Vec4;
        round(): Vec4;
        floor(): Vec4;
        ceil(): Vec4;
        toString(): String;
    }

    interface Mat3 {
        right(): Vec2;
        up(): Vec2;
        translation(value?: Vec2): Vec2;
        angle(): Number;
        multiply(other: Mat3 | Number): Mat3;
        translate(offset: Vec2): Mat3;
        rotate(angle: Number): Mat3;
        scale(factor: Vec2): Mat3;
        transformPoint(point: Vec2): Vec2;
        transformDirection(direction: Vec2): Vec2;
        transpose(): Mat3;
        inverse(): Mat3;
        copy(): Mat3;
    }

    interface Mat4 {
        right(): Vec3;
        up(): Vec3;
        forward(): Vec3;
        translation(value?: Vec3): Vec3;
        multiply(other: Mat4 | Number): Mat4;
        translate(offset: Vec3): Mat4;
        rotate(angle: Number, axis: Vec3): Mat4;
        scale(factor: Vec3): Mat4;
        transformPoint(point: Vec3): Vec3;
        transformDirection(direction: Vec3): Vec3;
        transpose(): Mat4;
        inverse(): Mat4;
        copy(): Mat4;
    }

    /** import * as WEMath from 'WEMath'; */
    interface WEMathModule {
        readonly deg2rad: Number;
        readonly rad2deg: Number;
        smoothStep(min: Number, max: Number, value: Number): Number;
        mix(a: Number, b: Number, amount: Number): Number;
    }

    /** import * as WEVector from 'WEVector'; */
    interface WEVectorModule {
        angleVector2(angle: Number): Vec2;
        vectorAngle2(direction: Vec2): Number;
    }

    /** import * as WEColor from 'WEColor'; */
    interface WEColorModule {
        rgb2hsv(rgb: Vec3): Vec3;
        hsv2rgb(hsv: Vec3): Vec3;
        normalizeColor(color: Vec3): Vec3;
        expandColor(color: Vec3): Vec3;
    }

    /** The layer the script runs on. */
    declare const thisLayer: AnyLayer;
    /** The object the script's property belongs to: the layer, an effect or a material. */
    declare const thisObject: AnyLayer & IEffect;
    declare const thisScene: IScene;
    declare const engine: IEngine;
    declare const input: IInput;
    declare const console: IConsole;
    declare const localStorage: ILocalStorage;
    /** One object every script of the scene shares. */
    declare const shared: Object;
    /** Declares the script's properties: createScriptProperties().addSlider({…}).finish(). */
    declare function createScriptProperties(): ScriptPropertiesBuilder;
    declare class Vec2: Vec2;
    declare class Vec3: Vec3;
    declare class Vec4: Vec4;
    declare class Mat3: Mat3;
    declare class Mat4: Mat4;
    declare class MediaPlaybackEvent: MediaPlaybackEventClass;
    declare module WEMath: WEMathModule;
    declare module WEVector: WEVectorModule;
    declare module WEColor: WEColorModule;
    """#
}
