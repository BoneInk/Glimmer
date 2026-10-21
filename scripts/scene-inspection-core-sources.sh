#!/bin/bash
# Read-only Scene subset inspection; deliberately excludes the native runtime/UI.
SCENE_INSPECTION_CORE_SOURCES=(
 "$ROOT/Sources/Glimmer/AuthorProperties/GWJSONValue.swift"
 "$ROOT/Sources/Glimmer/SceneWallpaper/SceneScriptSpec.swift"
 "$ROOT/Sources/Glimmer/SceneWallpaper/SceneWallpaperTypes.swift"
 "$ROOT/Sources/Glimmer/SceneWallpaper/SceneHierarchy.swift"
 "$ROOT/Sources/Glimmer/SceneWallpaper/SceneAssetSource.swift"
 "$ROOT/Sources/Glimmer/SceneWallpaper/SceneEngineAssetResolver.swift"
 "$ROOT/Sources/Glimmer/SceneWallpaper/ScenePackageArchive.swift"
 "$ROOT/Sources/Glimmer/SceneWallpaper/SceneTextureReader.swift"
 "$ROOT/Sources/Glimmer/SceneWallpaper/SceneTextRenderer.swift"
 "$ROOT/Sources/Glimmer/SceneWallpaper/SceneDXTDecoder.swift"
 "$ROOT/Sources/Glimmer/SceneWallpaper/SceneLZ4Block.swift"
 "$ROOT/Sources/Glimmer/SceneWallpaper/SceneWallpaperInspector.swift"
)
