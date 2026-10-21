#!/bin/bash
# Shared focused-test dependencies of the multi-renderer desktop and thumbnail code.
AUTHOR_WEB_CORE_SOURCES=(
  "$ROOT/Sources/Glimmer/AuthorProperties/"*.swift
  "$ROOT/Sources/Glimmer/AuthorPropertyAssets/"*.swift
  "$ROOT/Sources/Glimmer/WebWallpaper/"*.swift
  "$ROOT/Sources/Glimmer/SceneWallpaper/"*.swift
  "$ROOT/Sources/Glimmer/SceneScript/"*.swift
  "$ROOT/Sources/Glimmer/Support/WebWallpaperProjectDescriptor.swift"
  "$ROOT/Sources/Glimmer/Support/WebWallpaperProject.swift"
  "$ROOT/Sources/Glimmer/Support/SceneProjectDescriptor.swift"
  "$ROOT/Sources/Glimmer/Support/SceneProjectImporter.swift"
  "$ROOT/Sources/Glimmer/Support/AuthorPropertyServices.swift"
)
